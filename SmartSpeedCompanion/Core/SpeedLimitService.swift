// SpeedLimitService.swift
// Orchestrator that picks the best speed-limit answer for the user's current coord.
//
// Decision tree (Phase 2 polish + Phase 4 continuity guard):
//   1. Spatial-grid cache lookup -> hit short-circuits everything below.
//   1.5. SQLite-fast-path -- if the user is within ~1 km of a known AZ road corridor
//        (ArizonaSpeedLimitService.hasNearbyCoverage), try the local SQLite first.
//        Success skips the network round-trip; snap failure falls through.
//   2. If NetworkReachability.isConnected:
//        Walk liveProviders in order (ArcGIS HPMS -> Overpass) -- first non-nil
//        response wins. On network/parse failure for a provider, drop and try the next.
//   3. SQLite fallback (offline, or all live providers missed) -- with ExpandedSearch
//        retry and miss-grace window before dropping state to "No Data".
//   4. SQLite miss raises missCount; at missThresholdBeforeClear consecutive misses
//      we clear the local caches so stale bounding boxes can't pin us.
//
// Trade-off note: the 30-min memory cache TTL combined with sqlite-first means a
// recently-installed sign change can be silently stale for up to 30 min in the same
// 50 m cell. Acceptable for the polish pass -- background live verification can be
// added later as shadow-verify if the staleness proves user-visible.
//
// @Published dataSource is a typed SpeedLimitDataSource enum. Step 1.5 surfaces the
// same .localDB source as the existing sqlite-fallback path.
//
// PHASE 4 -- SpeedLimit Continuity Guard
// --------------------------------------
// When the user drives under a flyover (e.g. South Alma School Road under US-60 in
// Mesa/Chandler, AZ), CLGeocoder can briefly resolve `roadName` to the OVERPASS
// road for ~3-5 seconds while the underlying arterial's name re-resolves. The
// orchestrator then returns the freeway's 75 mph for that window, before SQLite
// name-match corrects back to 45 mph.
//
// The guard dampens that flicker WITHOUT blocking legitimate road transitions:
//   * Small speed delta (<= 20 mph) OR same-road identity  -> commit immediately
//     (normal driver behavior on the same road).
//   * Speed delta > 20 mph AND conflicting road identity   -> SUSPECT. Hold the
//     prior committed limit for up to 5 fetches. A second fetch that reproduces
//     the suspect identity commits it (real transition). A second fetch that
//     disagrees (e.g. SQLite name-match wins) commits THAT, dropping the suspect.
//   * Physics override: if `|new - currentSpeed| <= 10 mph` AND the prior limit
//     was already off-physics, commit immediately even with a big delta. This
//     case models a real highway on-ramp -- the driver is accelerating at 72 mph,
//     so the 75 mph answer is the only one matching physics regardless of (false)
//     geocode.
//   * Sink-in: 5 consecutive suspect fetches with the same identity commit anyway
//     (long-term geocode stuck -- user has clearly changed roads).
//
// IMPORTANT: the guard fires BEFORE cache writes, so the 75 mph flyover flicker
// does NOT poison the speedLimitResponseCache for the next fetch in the same
// 50 m cell.
//
// KNOWN LIMITATION (documented for future readers): `@MainActor` only serializes
// *between* awaits. If `SpeedEngine` fires two `updateSpeedLimit` calls in
// parallel (rare due to 80 m / 250 m throttle, but possible at highway speeds),
// whichever task completes first wins `lastStable`. In a flyover flicker the
// "wrong" candidate (e.g. 75 mph US-60) racing ahead of the SQLite 45 mph
// answer can invert the hold direction -- the user sees 75 for up to 5 fetches
// before sink-in. The throttle + cache.write delay bound this to ~3-5 sec at
// most; if it ever becomes visible in telemetry, the fix is to tag responses
// with a monotonic fetch id and have `finalizeWithContinuity` only consider
// the candidate whose fetch is strictly newer.

import Foundation
import CoreLocation
import Combine

@MainActor
public class SmartSpeedLimitService: ObservableObject {
    public static let shared = SmartSpeedLimitService()

    @Published public var currentLimit: Int = 0
    @Published public var dataSource: SpeedLimitDataSource = .noData

    private var lastValidLimit: Int = 0
    private var consecutiveMissCount: Int = 0
    /// After 20 consecutive misses, auto-clear the local caches so stale
    /// bounding boxes can't pin us to the wrong road.
    /// -- AUTHORITATIVE BASIS (research 2026-07): 20 consec misses = ~20-83
    ///   sec depending on fetch cadence (1 Hz GPS on surface streets vs the
    ///   250 m highway throttle at 75 mph). Google Roads API docs recommend
    ///   5-15 min intervals for asset tracking; 20-83 sec is intentionally
    ///   far shorter -- a brief outage doesn't pin stale data while a long
    ///   outage clears caches for live re-resolution.
    private let missThresholdBeforeClear: Int = 20

    private let liveProviders: [SpeedLimitProvider]
    private let reachability = NetworkReachability.shared
    private let cache = SpeedLimitResponseCache.shared

    // MARK: - Continuity Guard state

    /// A committed "stable" candidate. Replaced only when the guard accepts a
    /// new candidate. The HUD's published `currentLimit`/`dataSource` match this.
    private struct ContinuitySnapshot {
        let limit: Int
        let source: SpeedLimitDataSource
        let roadKey: String
        let roadName: String?
        let committedAt: Date
    }
    private var lastStable: ContinuitySnapshot?
    private var pendingSuspect: ContinuitySnapshot?
    private var consecutiveSuspectCount: Int = 0

    /// `45 -> 65` (arterial->highway) stays below this bar; the user's reported
    /// `45 -> 75` flyover-resolve flicker exceeds it.
    /// -- AUTHORITATIVE BASIS (research 2026-07): NO US federal rule (MUTCD /
    ///   AASHTO / FHWA) specifies a numerical max-mph-delta between adjacent
    ///   speed zones. MUTCD governs transition sign LENGTH (deceleration
    ///   distance), not numerical delta. FHWA's *Speed Limit Setting Handbook*
    ///   uses the 85th-percentile design process. Work-zone management
    ///   literature treats 10-15 mph max-mph-delta as a design boundary;
    ///   beyond that, transition zones / additional signage are recommended.
    ///   20 mph is chosen
    ///   empirically to admit legitimate arterial->highway jumps while
    ///   rejecting the observed 30-mph flyover flicker.
    static let SUSPICIOUS_JUMP_MPH: Int = 20
    /// 5 consecutive fetches with the same suspect identity -- sink-in to the
    /// new answer instead of pinning the driver to a stale limit.
    /// Wall-clock duration depends on fetch cadence + vehicle speed:
    /// ~5 sec at 1 Hz GPS, ~25-45 sec at the 80 m / 250 m distance
    /// throttles (longer at lower speeds).
    /// -- AUTHORITATIVE BASIS (research 2026-07): Apple provides no public
    ///   `CLGeocoder.reverseGeocodeLocation` latency SLA. HIG rate-limits
    ///   geocoder calls but publishes no response-time guarantee. 5 was
    ///   chosen as a safety-net debounce; nothing in Apple's docs contradicts.
    static let SUSPICIOUS_FETCH_HOLD: Int = 5
    /// Max `|new_candidate - user_GPS_speed|` at which a candidate is treated
    /// as physically plausible enough to bypass the suspect hold. Models the
    /// highway on-ramp where the driver is accelerating onto a 75 mph road.
    /// -- AUTHORITATIVE BASIS (research 2026-07): combined worst-case reading
    ///   * Speedometer accuracy: 49 CFR §393.82 (CMV) requires +/- 5 mph at
    ///     50 mph. No comparable FMVSS rule exists for US passenger vehicles.
    ///   * iPhone CLLocationSpeed: typically +/- 0.2-0.5 mph under open-sky;
    ///     worst-case +/- 2-3 mph during multipath / signal degradation;
    ///     Apple publishes no numerical accuracy SLA.
    ///   Combined worst-case: ~5-8 mph. 10 mph is deliberately generous to
    ///   avoid false positives at the cost of allowing wider tolerance.
    static let PHYSICS_TOLERANCE_MPH: Int = 10
    /// Min `|prior_limit - user_GPS_speed|` for the physics override to fire.
    /// Must exceed PHYSICS_TOLERANCE_MPH so the override never commits a
    /// candidate it should have held. Models "the driver has clearly
    /// abandoned the old road" (e.g. accelerating from 45 to 72 mph on a
    /// US-60 on-ramp).
    /// -- AUTHORITATIVE BASIS (research 2026-07): NO FHWA / AASHTO
    ///   "inter-road-class mph gap" rule exists. 15 mph is chosen empirically
    ///   as a typical arterial->highway speed differential observed in real
    ///   driving.
    static let PHYSICS_PRIOR_MARGIN_MPH: Int = 15

    // MARK: - HERE intentionally disabled (Phase 3 deferred)
    //
    // The HERE REST provider is implemented on disk:
    //   - SmartSpeedCompanion/Core/HERERestSpeedLimitProvider.swift
    //   - SmartSpeedCompanion/Core/HERECredentialStore.swift
    //   - SpeedLimitDataSource.liveHERE enum case
    //   - sourceForProviderName(_:) "HERE REST" -> .liveHERE mapping
    // but is intentionally NOT instantiated in liveProviders below.
    //
    // Do NOT re-add HERERestSpeedLimitProvider() to liveProviders without
    // verifying (a) the user's HERE credentials are loaded in Keychain via
    // HERECredentialStore.saveCredentials(...), and (b) a working bootstrap UI
    // exists for end users to paste their access_key_id / access_key_secret.
    // Without those, the provider silently returns nil on every call and the
    // chain just spends a network round-trip on every GPS update.

    private init() {
        self.liveProviders = [
            ArcGISHPMSSpeedLimitProvider(),
            OverpassSpeedLimitProvider(),
        ]
        // Preload any persisted entries from disk so the very first fetch can
        // avoid the network round-trip if the user is revisiting a road.
        Task { await cache.loadFromDisk() }
    }

    /// Pick the best speed limit at the user's current coord. Returns the new
    /// limit value and updates the @Published `currentLimit` + `dataSource`
    /// properties.
    ///
    /// `roadName` is the reverse-geocoded road name from RoadGeocoder. When
    /// non-nil it's threaded into Pass 1 SQLite scoring so a name match
    /// decisively outscores a name-mismatched big-bbox freeway candidate
    /// (the West Frye Rd vs S 202 case).
    public func updateSpeedLimit(
        at coordinate: CLLocationCoordinate2D,
        heading: Double?,
        currentSpeedMph: Double,
        roadName: String? = nil
    ) async -> Int {
        let outcome = await resolveCandidate(
            at: coordinate, heading: heading,
            currentSpeedMph: currentSpeedMph, roadName: roadName
        )
        return await finalizeWithContinuity(
            outcome: outcome,
            currentSpeedMph: currentSpeedMph,
            coordinate: coordinate,
            roadName: roadName
        )
    }

    // MARK: - Candidate resolution (decision-tree)

    /// Internal value type: a candidate answer from the resolver chain, OR a
    /// bouncer miss when the chain returned no data this fetch.
    private struct Candidate {
        let limit: Int
        let source: SpeedLimitDataSource
        let roadKey: String
        let providerName: String
        let detail: String
        /// True when the chain returned no data this fetch (SQLite fallback
        /// missed too). The continuity guard forwards misses to the grace
        /// window / cache-clear logic.
        let isMiss: Bool
    }

    /// Resolve the speed limit from the chain: cache -> sqlite-fast-path ->
    /// live providers -> sqlite fallback. NEVER writes to the response cache
    /// here -- cache writes happen only on commit, after the continuity guard
    /// clears the candidate.
    private func resolveCandidate(
        at coordinate: CLLocationCoordinate2D,
        heading: Double?,
        currentSpeedMph: Double,
        roadName: String?
    ) async -> Candidate {
        // 1. Cache short-circuit.
        if let cached = await cache.lookup(at: coordinate, roadName: roadName) {
            return Candidate(
                limit: cached.speedLimitMph,
                source: sourceForProviderName(cached.providerName),
                roadKey: cached.roadKey,
                providerName: cached.providerName,
                detail: cached.detail,
                isMiss: false
            )
        }

        // 1.5. SQLite-fast-path. Within a known ~1 km corridor, hit the local
        // SQLite first. Snap failure falls through to live providers.
        if await ArizonaSpeedLimitService.shared.hasNearbyCoverage(
            at: coordinate, heading: heading
        ) {
            if let sqliteLimit = try? await ArizonaSpeedLimitService.shared.updateSpeedLimit(
                at: coordinate, heading: heading,
                currentSpeedMph: currentSpeedMph, roadName: roadName
            ), sqliteLimit > 0 {
                let detail = roadName.map { "Local SQLite lookup along \($0)" }
                    ?? "Local SQLite lookup within 1 km corridor"
                return Candidate(
                    limit: sqliteLimit, source: .localDB,
                    roadKey: "local-sqlite", providerName: "AZ SQLite",
                    detail: detail, isMiss: false
                )
            }
            // Coverage exists but SQLite could not snap (heading mismatch,
            // intersection gap, etc.). Fall through to live providers.
        }

        // 2. Live provider chain (only when online).
        if reachability.isConnected {
            for provider in liveProviders {
                do {
                    if let resp = try await provider.fetchSpeedLimit(
                        at: coordinate, heading: heading
                    ), resp.speedLimitMph > 0 {
                        return Candidate(
                            limit: resp.speedLimitMph,
                            source: sourceForProviderName(resp.providerName),
                            roadKey: resp.roadKey,
                            providerName: resp.providerName,
                            detail: resp.detail,
                            isMiss: false
                        )
                    }
                } catch {
                    DebugLogger.shared.log("[\(provider.displayName)] Live fetch failed: \(error.localizedDescription)")
                    continue  // try the next provider in the chain
                }
            }
        }

        // 3. SQLite fallback (offline, or all live providers missed).
        return await querySQLiteFallback(
            at: coordinate, heading: heading,
            currentSpeedMph: currentSpeedMph, roadName: roadName
        )
    }

    /// SQLite fallback with ExpandedSearch retry. Returns a Miss candidate when
    /// both attempts fail so the continuity guard can apply the grace window.
    private func querySQLiteFallback(
        at coordinate: CLLocationCoordinate2D,
        heading: Double?,
        currentSpeedMph: Double,
        roadName: String?
    ) async -> Candidate {
        do {
            let localLimit = try await ArizonaSpeedLimitService.shared.updateSpeedLimit(
                at: coordinate, heading: heading,
                currentSpeedMph: currentSpeedMph, roadName: roadName
            )
            return Candidate(
                limit: localLimit, source: .localDB,
                roadKey: "local-sqlite", providerName: "AZ SQLite",
                detail: roadName.map { "Local SQLite fallback along \($0)" }
                    ?? "Local SQLite fallback within 1 km corridor",
                isMiss: false
            )
        } catch {
            consecutiveMissCount += 1

            if let recoveryLimit = try? await ArizonaSpeedLimitService.shared.updateSpeedLimit(
                at: coordinate, heading: heading,
                currentSpeedMph: currentSpeedMph, roadName: roadName,
                expandedSearch: true
            ) {
                return Candidate(
                    limit: recoveryLimit, source: .localDBRecovered,
                    roadKey: "local-sqlite-recovered", providerName: "AZ SQLite",
                    detail: "Expanded-search SQLite fallback",
                    isMiss: false
                )
            }

            return Candidate(
                limit: 0, source: .noData,
                roadKey: "", providerName: "", detail: "",
                isMiss: true
            )
        }
    }

    // MARK: - Continuity guard (commit / hold decision)

    /// Decide whether to commit the candidate, hold the prior, or sink-in.
    /// Misses are routed to `handleMiss` for the existing grace window.
    private func finalizeWithContinuity(
        outcome: Candidate,
        currentSpeedMph: Double,
        coordinate: CLLocationCoordinate2D,
        roadName: String?
    ) async -> Int {
        if outcome.isMiss {
            return await handleMiss(coordinate: coordinate, roadName: roadName)
        }

        let snapshot = ContinuitySnapshot(
            limit: outcome.limit, source: outcome.source,
            roadKey: outcome.roadKey, roadName: roadName,
            committedAt: Date()
        )

        guard let prior = lastStable else {
            // First-ever fetch -- commit unconditionally so we have a baseline.
            lastStable = snapshot
            pendingSuspect = nil
            consecutiveSuspectCount = 0
            return commit(candidate: outcome, coordinate: coordinate, roadName: roadName)
        }

        let speedDelta = abs(outcome.limit - prior.limit)
        let roadChanged = (roadName != prior.roadName) || (outcome.roadKey != prior.roadKey)

        // Rule 1 -- small delta or same-road identity: commit immediately.
        // Normal driving on the same road; doesn't flicker.
        if speedDelta <= Self.SUSPICIOUS_JUMP_MPH || !roadChanged {
            lastStable = snapshot
            pendingSuspect = nil
            consecutiveSuspectCount = 0
            return commit(candidate: outcome, coordinate: coordinate, roadName: roadName)
        }

        // Rule 2 -- physics override. The driver is moving at the new speed;
        // the answer matching physics wins regardless of an arguably false
        // geocode. Models highway on-ramp transitions cleanly.
        if abs(Double(outcome.limit) - currentSpeedMph) <= Double(Self.PHYSICS_TOLERANCE_MPH),
           abs(Double(prior.limit) - currentSpeedMph) > Double(Self.PHYSICS_PRIOR_MARGIN_MPH) {
            lastStable = snapshot
            pendingSuspect = nil
            consecutiveSuspectCount = 0
            return commit(candidate: outcome, coordinate: coordinate, roadName: roadName)
        }

        // Rule 3 -- suspect hold. Dampen the flyover-resolve flicker WITHOUT
        // blocking genuine road transitions.
        if let pending = pendingSuspect,
           pending.roadKey == snapshot.roadKey,
           pending.roadName == snapshot.roadName {
            consecutiveSuspectCount += 1
        } else {
            pendingSuspect = snapshot
            consecutiveSuspectCount = 1
        }

        if consecutiveSuspectCount >= Self.SUSPICIOUS_FETCH_HOLD {
            // 5 consecutive suspect fetches with the same identity -- the
            // road has changed and the geocode just hasn't caught up.
            // Sink in to avoid pinning the driver to the OLD limit forever.
            lastStable = snapshot
            pendingSuspect = nil
            consecutiveSuspectCount = 0
            return commit(candidate: outcome, coordinate: coordinate, roadName: roadName)
        }

        // Hold prior -- returns the previously committed limit to the caller
        // without publishing the suspect candidate or poisoning the cache.
        DebugLogger.shared.log("[ContinuityGuard] HOLD prior=\(prior.limit) holding back suspect=\(snapshot.limit) on \(snapshot.roadKey.isEmpty ? "(no roadKey)" : snapshot.roadKey) (count=\(consecutiveSuspectCount)/\(Self.SUSPICIOUS_FETCH_HOLD))")
        return prior.limit
    }

    /// Commit the candidate: publish to UI, persist to response cache, update
    /// lastValidLimit. Called only when the continuity guard clears a candidate.
    private func commit(
        candidate: Candidate,
        coordinate: CLLocationCoordinate2D,
        roadName: String?
    ) -> Int {
        if candidate.limit > 0 {
            self.lastValidLimit = candidate.limit
            self.consecutiveMissCount = 0
        }
        self.currentLimit = candidate.limit
        self.dataSource = candidate.source

        let resp = SpeedLimitResponse(
            speedLimitMph: candidate.limit,
            roadKey: candidate.roadKey,
            providerName: candidate.providerName,
            detail: candidate.detail
        )
        // Persist the response off the main actor -- the cache writes to disk
        // and would otherwise block the orchestrator's next fetch.
        Task { await cache.store(resp, at: coordinate, roadName: roadName) }
        return candidate.limit
    }

    /// Handle a resolver miss. Mirrors the previous catch-block logic: hold the
    /// last valid limit within a grace window, then clear caches if we cross
    /// the threshold.
    private func handleMiss(
        coordinate: CLLocationCoordinate2D,
        roadName: String?
    ) async -> Int {
        if consecutiveMissCount < missThresholdBeforeClear, lastValidLimit > 0 {
            // Grace window: keep the previous limit visible for up to 20
            // consecutive misses before giving up to "No Data".
            self.currentLimit = lastValidLimit
            return lastValidLimit
        }
        if consecutiveMissCount >= missThresholdBeforeClear {
            await ArizonaSpeedLimitService.shared.clearCache()
            await cache.clear()
            lastValidLimit = 0
            currentLimit = 0
            dataSource = .noData
            consecutiveMissCount = 0
        }
        return self.currentLimit
    }

    // MARK: - Helpers

    private func sourceForProviderName(_ name: String) -> SpeedLimitDataSource {
        switch name {
        case "HERE REST": return .liveHERE
        case "ArcGIS":    return .liveArcGIS
        case "Overpass":  return .liveOverpass
        case "AZ SQLite": return .localDB
        default:          return .noData
        }
    }
}
