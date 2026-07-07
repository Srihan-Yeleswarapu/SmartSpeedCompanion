// SpeedLimitService.swift
// Orchestrator that picks the best speed-limit answer for the user's current coord.
//
// Decision tree (Phase 2 polish expanded the live-fast-path):
//   1. Spatial-grid cache lookup -> hit short-circuits everything below.
//   1.5. SQLite-fast-path -- if the user is within ~1 km of a known AZ road corridor
//        (ArizonaSpeedLimitService.hasNearbyCoverage), try the local SQLite first.
//        Success skips the network round-trip; snap failure falls through.
//   2. If NetworkReachability.isConnected:
//        Walk liveProviders in order (HERE REST -> ArcGIS HPMS -> Overpass) -- first non-nil
//        response wins. On network/parse failure for a provider, drop and try the next.
//   3. SQLite fallback (offline, or all live providers missed) -- with ExpandedSearch
//        retry and 20-miss grace window before dropping state to "No Data".
//   4. SQLite miss raises missCount; at missThresholdBeforeClear consecutive misses we drop
//      state to "No Data" rather than pinning the driver to a stale segment.
//
// Trade-off note: the 30-min memory cache TTL combined with sqlite-first means a
// recently-installed sign change can be silently stale for up to 30 min in the same
// 50 m cell. Acceptable for the polish pass -- background live verification can be
// added later as shadow-verify if the staleness proves user-visible.
//
// @Published dataSource is a typed SpeedLimitDataSource enum. Step 1.5 surfaces the
// same .localDB source as the existing sqlite-fallback path.

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
    /// After 20 consecutive misses, auto-clear the spatial cache so stale bounding boxes
    /// can't pin us to the wrong road.
    private let missThresholdBeforeClear: Int = 20

    private let liveProviders: [SpeedLimitProvider]
    private let reachability = NetworkReachability.shared
    private let cache = SpeedLimitResponseCache.shared    private init() {
        // Order matters for accuracy on signed arterials: HERE REST relies on
        // the user's HERE Platform creds (Keychain). 250k requests/month free
        // permanently. Falls through on nil / 429 / 5xx / missing creds.
        self.liveProviders = [
            HERERestSpeedLimitProvider(),
            ArcGISHPMSSpeedLimitProvider(),
            OverpassSpeedLimitProvider(),
        ]   
        // Preload any persisted entries from disk so the very first fetch can
        // avoid the network round-trip if the user is revisiting a road.
        Task { await cache.loadFromDisk() }
    }

    /// Pick the best speed limit at the user's current coord. Returns the new limit value
    /// and updates the @Published `currentLimit` + `dataSource` properties.
    public func updateSpeedLimit(
        at coordinate: CLLocationCoordinate2D,
        heading: Double?,
        currentSpeedMph: Double
    ) async -> Int {
        // 1. Cache short-circuit.
        if let cached = await cache.lookup(at: coordinate) {
            apply(limit: cached.speedLimitMph,
                  source: sourceForProviderName(cached.providerName))
            return cached.speedLimitMph
        }

        // 1.5. SQLite-fast-path. Within a known ~1 km corridor, hit the local
        // SQLite first to avoid the network round-trip. Snap failure falls
        // through to live providers; the 30-min cache TTL bounds staleness.
        if await ArizonaSpeedLimitService.shared.hasNearbyCoverage(
            at: coordinate, heading: heading
        ) {
            if let sqliteLimit = try? await ArizonaSpeedLimitService.shared.updateSpeedLimit(
                at: coordinate, heading: heading, currentSpeedMph: currentSpeedMph
            ), sqliteLimit > 0 {
                let resp = SpeedLimitResponse(
                    speedLimitMph: sqliteLimit,
                    roadKey: "local-sqlite",
                    providerName: "AZ SQLite",
                    detail: "Local SQLite lookup within 1 km corridor"
                )
                await cache.store(resp, at: coordinate)
                apply(limit: sqliteLimit, source: .localDB)
                return sqliteLimit
            }
            // Coverage exists but SQLite could not snap at the user's coord
            // (heading mismatch, intersection gap, etc.). Fall through to live
            // providers for fresher data.
        }

        // 2. Live provider chain (only when online).
        if reachability.isConnected {
            for provider in liveProviders {
                do {
                    if let resp = try await provider.fetchSpeedLimit(at: coordinate, heading: heading),
                       resp.speedLimitMph > 0 {
                        await cache.store(resp, at: coordinate)
                        apply(limit: resp.speedLimitMph,
                              source: sourceForProviderName(resp.providerName))
                        return resp.speedLimitMph
                    }
                } catch {
                    DebugLogger.shared.log("[\(provider.displayName)] Live fetch failed: \(error.localizedDescription)")
                    continue  // try the next provider in the chain
                }
            }
        }

        // 3. SQLite fallback (offline, or all live providers missed).
        return await querySQLiteFallback(at: coordinate, heading: heading, currentSpeedMph: currentSpeedMph)
    }

    // MARK: - Private helpers

    private func querySQLiteFallback(
        at coordinate: CLLocationCoordinate2D,
        heading: Double?,
        currentSpeedMph: Double
    ) async -> Int {
        do {
            let localLimit = try await ArizonaSpeedLimitService.shared.updateSpeedLimit(
                at: coordinate,
                heading: heading,
                currentSpeedMph: currentSpeedMph
            )
            apply(limit: localLimit, source: .localDB)
            return localLimit
        } catch {
            consecutiveMissCount += 1

            // ExpandedSearch with 60m radius.
            if let recoveryLimit = try? await ArizonaSpeedLimitService.shared.updateSpeedLimit(
                at: coordinate,
                heading: heading,
                currentSpeedMph: currentSpeedMph,
                expandedSearch: true
            ) {
                apply(limit: recoveryLimit, source: .localDBRecovered)
                return recoveryLimit
            }

            // Hold the last valid limit for a grace window of 20 misses before giving up.
            if consecutiveMissCount < missThresholdBeforeClear && lastValidLimit > 0 {
                self.currentLimit = lastValidLimit
                return lastValidLimit
            } else if consecutiveMissCount >= missThresholdBeforeClear {
                await ArizonaSpeedLimitService.shared.clearCache()
                await cache.clear()
                lastValidLimit = 0
                currentLimit = 0
                dataSource = .noData
                consecutiveMissCount = 0
            }
            return self.currentLimit
        }
    }

    private func apply(limit: Int, source: SpeedLimitDataSource) {
        if limit > 0 {
            self.lastValidLimit = limit
            self.consecutiveMissCount = 0
        }
        self.currentLimit = limit
        self.dataSource = source
    }

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
