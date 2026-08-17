// SpeedLimitService.swift
// Orchestrator that picks the best speed-limit answer for the user's current coord.
//
// Decision tree (cache-first / rate-limit-first; HERE-only):
//   1. Consult the short-lived HERE response cache (local memory, 30 min TTL,
//      spatial grid keyed by the user's location). If we already know this
//      location, we send NO network request at all.
//   2. Consult the validated HERE batch cache (SQLite, populated by the
//      initial 2.5km setup grid + just-in-time geofence triggers).
//   3. Only when BOTH local caches miss (or the user tapped manual refresh)
//      do we query HERE REST live — and the provider's own 100 m success
//      distance throttle further caps how often genuinely-new locations
//      actually hit the API.
//   4. If all HERE paths miss, return No Data and let the continuity guard
//      apply its normal miss-grace window.
//
// Trade-off note: cache-first means a recently-installed sign change is only
// picked up after the response cache TTL expires (30 min) or the batch cache
// is refreshed — the deliberate cost of protecting the HERE freemium rate
// limit (250k requests/month) from a 1-Hz GPS loop. Manual refresh still
// bypasses every cache so the driver can force a live answer anytime.
//
// @Published dataSource retains legacy localDB cases for decoding compatibility,
// but this service never creates or publishes them.
//
// PHASE 4 -- SpeedLimit Continuity Guard
// --------------------------------------
// When the user drives under a flyover, reverse geocoding can briefly resolve
// `roadName` to a nearby road for ~3-5 seconds while the underlying arterial's
// name re-resolves. The
// continuity guard holds a suspect live-provider answer during that window
// instead of allowing a nearby road result to flicker onto the HUD.
//
// The guard dampens that flicker WITHOUT blocking legitimate road transitions:
//   * Small speed delta (<= SUSPICIOUS_JUMP_MPH=15 mph) AND no
//     geocoder-provider disagreement  -> commit immediately
//     (normal driver behavior on the same road).
//   * Geocoder-provider road-name disagreement (geocoder says "same road"
//     but provider says "different road key") -> SUSPECT regardless of delta.
//     The geocoder is an independent ground-truth signal for "which road am I on?"
//     and any disagreement likely means a cross-street GPS snap.
//   * Speed delta > SUSPICIOUS_JUMP_MPH AND conflicting road identity -> SUSPECT.
//     Hold the prior committed limit for up to 3 fetches. A second fetch that
//     reproduces the suspect identity commits it (real transition). A second fetch
//     that disagrees commits that result, dropping the suspect.
//   * Physics override: if `|new - currentSpeed| <= 10 mph` AND the prior limit
//     was already off-physics, commit immediately even with a big delta. This
//     case models a real highway on-ramp -- the driver is accelerating at 72 mph,
//     so the 75 mph answer is the only one matching physics regardless of (false)
//     geocode.
//   * Sink-in: 3 consecutive suspect fetches with the same identity commit anyway
//     (long-term geocode stuck -- user has clearly changed roads).
//
// IMPORTANT: the guard fires BEFORE cache writes, so the 75 mph flyover flicker
// does NOT poison the speedLimitResponseCache for the next fetch in the same
// 50 m cell.
//
// Concurrency note: `@MainActor` serializes state transitions between awaits,
// while `latestUpdateGeneration` below makes the newest overlapping GPS/manual
// request authoritative before continuity state or HUD values are committed.

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

    /// HERE Route Matching batch cache — populated on initial setup and
    /// refreshed via just-in-time geofence triggers as the user drives.
    private let batchCache = HERELocalBatchCache.shared

    /// HERE REST provider used for live lookups. Kept as a collection so the
    /// provider abstraction remains easy to test without reintroducing fallback
    /// sources.
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
    /// Monotonic token for published GPS-driven fetches. Provider requests
    /// await network/database work, so an older location can finish after a
    /// newer one unless stale completions are explicitly discarded.
    private var latestUpdateGeneration: UInt64 = 0
    /// Unique process-local revision for every committed cache write.
    private var nextCacheStoreRevision: UInt64 = 0

    /// `45 -> 65` (arterial->highway) stays below this bar; the user's reported
    /// `45 -> 25` Bush Rd cross-street snap (20 mph delta) exceeds it.
    /// -- AUTHORITATIVE BASIS (research 2026-07): NO US federal rule (MUTCD /
    ///   AASHTO / FHWA) specifies a numerical max-mph-delta between adjacent
    ///   speed zones. MUTCD governs transition sign LENGTH (deceleration
    ///   distance), not numerical delta. FHWA's *Speed Limit Setting Handbook*
    ///   uses the 85th-percentile design process. Work-zone management
    ///   literature treats 10-15 mph max-mph-delta as a design boundary;
    ///   beyond that, transition zones / additional signage are recommended.
    ///   15 mph was chosen
    ///   empirically after TestFlight feedback showed a 45→25 cross-street
    ///   snap (20 mph delta) was committed immediately. Lowering from 20 to
    ///   15 catches that snap while still admitting legitimate transitions
    ///   like 30→25 on a side street or 45→55 on a highway on-ramp.
    static let SUSPICIOUS_JUMP_MPH: Int = 15
    /// 3 consecutive fetches with the same suspect identity -- sink-in to the
    /// new answer instead of pinning the driver to a stale limit.
    /// Lowered from 5 to 3 so genuine road transitions sink in faster
    /// (the heading-delta trigger at 20° now fires more re-fetches,
    /// so suspects accumulate faster; 3 fetches at 500ms cadence ≈ 1.5 sec
    /// of suspect data before committing).
    /// -- AUTHORITATIVE BASIS (research 2026-07): Apple provides no public
    ///   `CLGeocoder.reverseGeocodeLocation` latency SLA. HIG rate-limits
    ///   geocoder calls but publishes no response-time guarantee. 3 was
    ///   chosen as a tighter debounce that still rejects flyover flicker
    ///   (~3-5 sec typical) while accepting real transitions faster.
    static let SUSPICIOUS_FETCH_HOLD: Int = 3
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

    // MARK: - Live provider chain
    //
    // HERE REST is the sole active live provider. ArcGIS and Overpass remain
    // in the repository for research/offline tooling, but must never silently
    // become the source of a driving alert or HUD limit.
    // The HERE provider aligns its short probe with the vehicle course whenever
    // one is available, avoiding the old eastward-only probe at intersections.
    private init() {
        self.liveProviders = [
            HERERestSpeedLimitProvider(),
        ]
        // Preload the in-memory response cache from disk so the very first
        // fetch can hit cached data without a network round-trip.
        // The SQLite batch cache (HERELocalBatchCache) is self-persisting
        // and requires no explicit loadFromDisk call.
        Task {
            await cache.loadFromDisk()
        }
    }

    /// Clear the service's published answer before a new GPS/manual resolution.
    /// SpeedEngine clears its own limit at the same boundary; resetting both
    /// properties keeps the HUD's number and provenance chip atomic instead of
    /// leaving an old provider label under a new/unknown answer.
    public func beginResolution() {
        currentLimit = 0
        dataSource = .noData
    }

    /// Pick the best speed limit at the user's current coord. Returns the new
    /// limit value and updates the @Published `currentLimit` + `dataSource`
    /// properties.
    ///
    /// `roadName` is the reverse-geocoded road name from RoadGeocoder. It is
    /// passed to live providers and cache lookups for road-aware matching.
    public func updateSpeedLimit(
        at coordinate: CLLocationCoordinate2D,
        heading: Double?,
        currentSpeedMph: Double,
        roadName: String? = nil,
        forceRefresh: Bool = false
    ) async -> Int {
        // Keep the service's number and provenance synchronized with the
        // SpeedEngine refresh boundary. This prevents an old OSM/legacy label
        // from surviving underneath the cleared sign while HERE resolves.
        beginResolution()
        latestUpdateGeneration &+= 1
        let generation = latestUpdateGeneration
        let outcome = await resolveCandidate(
            at: coordinate, heading: heading,
            currentSpeedMph: currentSpeedMph,
            roadName: roadName,
            forceRefresh: forceRefresh
        )
        // A newer GPS/manual request is authoritative. Do not let a slow
        // provider response from the previous road overwrite the current HUD.
        guard generation == latestUpdateGeneration else { return currentLimit }
        let result = await finalizeWithContinuity(
            outcome: outcome,
            currentSpeedMph: currentSpeedMph,
            coordinate: coordinate,
            roadName: roadName,
            generation: generation,
            forceRefresh: forceRefresh
        )
        // `finalizeWithContinuity` may await cache-clearing work for a miss;
        // do not return a stale result if another request became authoritative
        // during that await.
        guard generation == latestUpdateGeneration else { return currentLimit }
        return result
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
        /// True when the active cache/provider chain returned no data this fetch.
        /// The continuity guard forwards misses to the grace window logic.
        let isMiss: Bool
    }

    /// Resolve the speed limit from the active HERE path: response cache -> HERE
    /// batch cache -> HERE REST. NEVER writes to the response cache here -- cache
    /// writes happen only on commit, after the continuity guard clears the
    private func resolveCandidate(
        at coordinate: CLLocationCoordinate2D,
        heading: Double?,
        currentSpeedMph: Double,
        roadName: String?,
        forceRefresh: Bool = false
    ) async -> Candidate {
        // RATE-LIMIT-FIRST (cache-first) ordering. The user asked for local
        // memory to be consulted BEFORE any network request: if we already
        // have the answer for this location cached (response cache in memory,
        // then the SQLite batch cache), we do NOT send a HERE request at all.
        // HERE REST is only contacted when BOTH local caches miss — a brand
        // new road or cell. Manual refresh (`forceRefresh`) still bypasses
        // every cache so the user's tap always runs the live provider chain.

        // 1. Response cache — the short-lived in-memory (30 min) spatial grid
        //    cache keyed by the user's location. This is the "do we already
        //    know this place?" check: a location we have cached costs zero
        //    network requests, which protects the HERE freemium rate limit.
        if !forceRefresh,
           let roadName,
           !roadName.isEmpty,
           let cached = await cache.lookup(at: coordinate, roadName: roadName),
           isHEREProviderName(cached.providerName) {
            return Candidate(
                limit: cached.speedLimitMph,
                source: sourceForProviderName(cached.providerName),
                roadKey: cached.roadKey,
                providerName: cached.providerName,
                detail: cached.detail,
                isMiss: false
            )
        }

        // 2. Batch cache lookup (HERE Route Matching API results) — SQLite,
        //    populated by the initial 2.5km setup grid and just-in-time
        //    geofence triggers as the user drives. Primary path: road name +
        //    direction (O(log n)); fallback: spatial nearest-neighbor within
        //    50m. Also skips when `forceRefresh` so the tap can override a
        //    wrong batch-cached limit.
        if !forceRefresh,
           let roadName,
           !roadName.isEmpty {
            let cached = batchCache.lookup(
                coordinate: coordinate,
                roadName: roadName,
                bearing: heading
            )
            if let cached, cached.source.caseInsensitiveCompare("here") == .orderedSame {
                return Candidate(
                    limit: cached.speedLimitMph,
                    source: .batchCache,
                    roadKey: cached.roadName + (cached.direction.isEmpty ? "" : " \(cached.direction)"),
                    providerName: "HERE Batch",
                    detail: "Batch cache on \(roadName)",
                    isMiss: false
                )
            }
        }

        // 3. Live HERE — ONLY when both local caches missed (brand new
        //    location or the user tapped manual refresh). The REST provider's
        //    own distance throttle (100 m since last success) further limits
        //    how often a genuinely-new location actually hits the API.
        if reachability.isConnected,
           let live = await liveHERECandidate(
                at: coordinate,
                heading: heading,
                forceRefresh: forceRefresh
           ) {
            return live
        }

        // 4. HERE and local caches have no data. Returning a miss keeps all
        // regions on the same path and prevents an unrelated map-data source
        // from becoming authoritative.
        return Candidate(
            limit: 0, source: .noData,
            roadKey: "", providerName: "", detail: "",
            isMiss: true
        )
    }

    /// Query the sole active live provider and convert its response into the
    /// service's candidate type. A nil result means HERE was throttled or had
    /// no usable coverage, so the caller may safely try a local cache.
    private func liveHERECandidate(
        at coordinate: CLLocationCoordinate2D,
        heading: Double?,
        forceRefresh: Bool
    ) async -> Candidate? {
        for provider in liveProviders {
            do {
                if let resp = try await provider.fetchSpeedLimit(
                    at: coordinate, heading: heading, forceRefresh: forceRefresh
                ), resp.providerName == "HERE REST", resp.speedLimitMph > 0 {
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
            }
        }
        return nil
    }

    // MARK: - Continuity guard (commit / hold decision)

    /// Decide whether to commit the candidate, hold the prior, or sink-in.
    /// Misses are routed to `handleMiss` for the existing grace window.
    private func finalizeWithContinuity(
        outcome: Candidate,
        currentSpeedMph: Double,
        coordinate: CLLocationCoordinate2D,
        roadName: String?,
        generation: UInt64,
        forceRefresh: Bool
    ) async -> Int {
        guard generation == latestUpdateGeneration else { return currentLimit }
        if outcome.isMiss {
            // A manual refresh is an explicit request to discard the displayed
            // answer if the fresh provider chain has no result. Do not keep a
            // potentially wrong 25 mph answer alive through the normal miss
            // grace window after the user tapped the sign.
            if forceRefresh {
                lastValidLimit = 0
                consecutiveMissCount = 0
                lastStable = nil
                pendingSuspect = nil
                consecutiveSuspectCount = 0
                currentLimit = 0
                dataSource = .noData
                await cache.invalidate(at: coordinate, roadName: roadName)
                batchCache.invalidate(at: coordinate, roadName: roadName)
                return 0
            }

            // Keep the proposed count local until every awaited cache-clear
            // operation completes. An older request may enter this branch,
            // then become stale while the next request starts; publishing its
            // count early would contaminate the newer request's grace window.
            let proposedMissCount = consecutiveMissCount + 1
            let result = await handleMiss(
                coordinate: coordinate,
                roadName: roadName,
                generation: generation,
                missCount: proposedMissCount
            )
            guard generation == latestUpdateGeneration else { return currentLimit }
            consecutiveMissCount = result.missCount
            return result.limit
        }

        let snapshot = ContinuitySnapshot(
            limit: outcome.limit, source: outcome.source,
            roadKey: outcome.roadKey, roadName: roadName,
            committedAt: Date()
        )
        // The active service is HERE-only. Keep this invariant at the final
        // publication boundary as well as in provider resolution, so stale
        // persisted/cache data can never relabel a positive HUD answer as OSM.
        guard outcome.source == .liveHERE || outcome.source == .batchCache else {
            dataSource = .noData
            currentLimit = 0
            return 0
        }

        guard let prior = lastStable else {
            // First-ever fetch -- commit unconditionally so we have a baseline.
            lastStable = snapshot
            pendingSuspect = nil
            consecutiveSuspectCount = 0
            return commit(candidate: outcome, coordinate: coordinate, roadName: roadName, generation: generation)
        }

        // A manual refresh bypasses caches and provider throttles. It is an
        // explicit request to replace the displayed answer with the current
        // HERE result, including a lower limit after a legitimate road change.
        // Cross-provider false positives cannot enter because HERE REST is the
        // sole live provider and caches enforce the HERE allowlist.
        if forceRefresh {
            lastStable = snapshot
            pendingSuspect = nil
            consecutiveSuspectCount = 0
            return commit(candidate: outcome, coordinate: coordinate, roadName: roadName, generation: generation)
        }

        let speedDelta = abs(outcome.limit - prior.limit)

        // Rule 1 -- small delta: commit immediately.
        // EXCEPTION: when the geocoded road name is available and matches the
        // prior geocoded road name (geocoder says "same road"), but the
        // provider's road key differs from the prior provider road key
        // (provider says "different road"), the geocoder and provider disagree.
        // The geocoder is an independent ground-truth signal for "which road am
        // I on?" — any disagreement likely means a cross-street GPS snap where
        // the provider returned data for a nearby different road. Route through
        // the suspect hold even for small deltas.
        if speedDelta <= Self.SUSPICIOUS_JUMP_MPH {
            // Geocoder-provider road-name cross-check:
            //   roadName == prior.roadName  AND  outcome.roadKey != prior.roadKey
            // means the geocoder says "same road" but the provider disagrees.
            let geocoderSaysSameRoad = (roadName != nil && prior.roadName != nil && roadName == prior.roadName && !roadName!.isEmpty)
            let providerSaysDifferentRoad = (outcome.roadKey != prior.roadKey && !outcome.roadKey.isEmpty && !prior.roadKey.isEmpty)
            if geocoderSaysSameRoad && providerSaysDifferentRoad {
                // Geocoder and provider disagree — likely a cross-street GPS
                // snap. Fall through to the suspect hold below.
                DebugLogger.shared.log("[ContinuityGuard] HOLD (geocoder-provider mismatch): prior=\(prior.limit) on '\(prior.roadName ?? "")' vs candidate=\(outcome.limit) roadKey=\(outcome.roadKey)")
            } else {
                // Road identity is consistent, or geocoder has no opinion
                // (nil roadName). Commit immediately.
                lastStable = snapshot
                pendingSuspect = nil
                consecutiveSuspectCount = 0
                return commit(candidate: outcome, coordinate: coordinate, roadName: roadName, generation: generation)
            }
        }

        // Rule 2 -- physics override. The driver is moving at the new speed;
        // the answer matching physics wins regardless of an arguably false
        // geocode. Models highway on-ramp transitions cleanly.
        if outcome.limit > prior.limit,
           abs(Double(outcome.limit) - currentSpeedMph) <= Double(Self.PHYSICS_TOLERANCE_MPH),
           abs(Double(prior.limit) - currentSpeedMph) > Double(Self.PHYSICS_PRIOR_MARGIN_MPH) {
            lastStable = snapshot
            pendingSuspect = nil
            consecutiveSuspectCount = 0
            return commit(candidate: outcome, coordinate: coordinate, roadName: roadName, generation: generation)
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
            // 3 consecutive suspect fetches with the same identity -- the
            // road has changed and the geocode just hasn't caught up.
            // Sink in to avoid pinning the driver to the OLD limit forever.
            lastStable = snapshot
            pendingSuspect = nil
            consecutiveSuspectCount = 0
            return commit(candidate: outcome, coordinate: coordinate, roadName: roadName, generation: generation)
        }

        // Hold prior -- returns the previously committed limit to the caller
        // without publishing the suspect candidate or poisoning the cache.
        // `beginResolution()` cleared the published answer before this
        // candidate arrived. Restore the complete prior presentation when the
        // continuity guard holds it; restoring only the number would leave a
        // positive limit paired with `No Data` (or an old OSM label) in the HUD.
        self.dataSource = prior.source
        self.currentLimit = prior.limit
        DebugLogger.shared.log("[ContinuityGuard] HOLD prior=\(prior.limit) holding back suspect=\(snapshot.limit) on \(snapshot.roadKey.isEmpty ? "(no roadKey)" : snapshot.roadKey) (count=\(consecutiveSuspectCount)/\(Self.SUSPICIOUS_FETCH_HOLD))")
        return prior.limit
    }

    /// Commit the candidate: publish to UI, persist to response cache, update
    /// lastValidLimit. Called only when the continuity guard clears a candidate.
    private func commit(
        candidate: Candidate,
        coordinate: CLLocationCoordinate2D,
        roadName: String?,
        generation: UInt64
    ) -> Int {
        if candidate.limit > 0 {
            self.lastValidLimit = candidate.limit
            self.consecutiveMissCount = 0
        }
        // Publish provenance first, then the number. The DriveViewModel source
        // binding combines both streams and will only show a provider label
        // once the corresponding positive limit is visible.
        self.dataSource = candidate.source
        self.currentLimit = candidate.limit

        let resp = SpeedLimitResponse(
            speedLimitMph: candidate.limit,
            roadKey: candidate.roadKey,
            providerName: candidate.providerName,
            detail: candidate.detail
        )
        // Persist the response off the main actor -- the cache writes to disk
        // and would otherwise block the orchestrator's next fetch.
        nextCacheStoreRevision &+= 1
        let cacheRevision = nextCacheStoreRevision
        // Never persist an answer without road context. A spatial-only
        // response can be the adjacent cross street at an intersection and
        // would otherwise poison future GPS lookups in the same cell.
        if let roadName, !roadName.isEmpty {
            Task { await cache.store(resp, at: coordinate, roadName: roadName, revision: cacheRevision) }
        }
        return candidate.limit
    }

    /// Handle a resolver miss. Mirrors the previous catch-block logic: hold the
    /// last valid limit within a grace window, then clear caches if we cross
    /// the threshold.
    ///
    /// ROAD-NAME-AWARE GRACE: when the geocoder reports a different road name
    /// than the one on which `lastValidLimit` was committed, the grace window
    /// shrinks from 20 to 3 consecutive misses. Holding a limit from a
    /// different road is worse than briefly showing "--". The small window
    /// still prevents flicker from GPS cross-street snaps at intersections.
    ///
    /// IMPORTANT: when the road-change effective threshold is exceeded
    /// (consecutiveMissCount >= effectiveThreshold), we drop to "--"
    /// immediately instead of continuing to return the stale `lastValidLimit`.
    private func handleMiss(
        coordinate: CLLocationCoordinate2D,
        roadName: String?,
        generation: UInt64,
        missCount: Int
    ) async -> (limit: Int, missCount: Int) {
        guard generation == latestUpdateGeneration else { return (currentLimit, consecutiveMissCount) }
        if missCount < missThresholdBeforeClear, lastValidLimit > 0 {
            // Detect road change: geocoder now says a different road than
            // when the committed limit was last established.
            let roadChanged: Bool = {
                guard let current = roadName, !current.isEmpty,
                      let committed = lastStable?.roadName, !committed.isEmpty else {
                    return false  // no geocode opinion either time = assume same road
                }
                return current != committed
            }()

            let effectiveThreshold = roadChanged ? min(3, missThresholdBeforeClear) : missThresholdBeforeClear

            if missCount < effectiveThreshold {
                // A provider miss is not an alertable speed limit. Keep the
                // prior answer only as internal continuity state; the HUD and
                // AlertEngine must see "No Data" immediately rather than
                // beeping against a stale/unknown limit.
                self.dataSource = .noData
                self.currentLimit = 0
                return (0, missCount)
            } else if roadChanged {
                // Road changed AND we've exceeded the road-change threshold.
                // Drop to "--" immediately instead of holding the stale
                // limit from the previous road.
                self.dataSource = .noData
                self.currentLimit = 0
                return (0, 0)
            }
        }
        if missCount >= missThresholdBeforeClear {
            guard generation == latestUpdateGeneration else { return (currentLimit, consecutiveMissCount) }
            // Capture the revision boundary before the response-cache clear can
            // suspend. Responses issued after this point receive a higher revision
            // and are preserved even if this miss becomes stale.
            let clearThroughRevision = nextCacheStoreRevision
            // Only the active response cache is cleared after sustained misses.
            await cache.clear(rejectingRevisionsThrough: clearThroughRevision)
            guard generation == latestUpdateGeneration else { return (currentLimit, consecutiveMissCount) }
            lastValidLimit = 0
            dataSource = .noData
            currentLimit = 0
            consecutiveMissCount = 0
            return (0, 0)
        }
        return (self.currentLimit, missCount)
    }

    // MARK: - Helpers

    private func isHEREProviderName(_ name: String) -> Bool {
        name == "HERE REST" || name == "HERE Batch"
    }

    private func sourceForProviderName(_ name: String) -> SpeedLimitDataSource {
        switch name {
        case "HERE Batch": return .batchCache
        case "HERE REST":  return .liveHERE
        // Non-HERE providers are intentionally not active. Keep the legacy
        // enum cases for decoding older persisted state, but do not surface
        // them as current driving data.
        case "ArcGIS", "Overpass": return .noData
        default:           return .noData
        }
    }
}
