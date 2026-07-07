// LookAroundCoordinator.swift
// Thin wrapper around MKLookAroundSceneRequest (iOS 16+) that:
//   - Caches returned MKLookAroundScene objects by coordinate-grid cell
//     (~30 m, enough to deduplicate successive lookups along a route without
//     polluting the cache).
//   - Caps cache size so we never grow unbounded during a long drive.
//   - Exposes a single in-flight Task via `currentTask`, so callers can cancel
//     when the user passes a turn before the scene arrives.
//
// This is purely native — MKLookAroundSceneRequest is a free, on-device
// MapKit API with no Apple Maps Server token required.

import Foundation
import MapKit
import CoreLocation

@MainActor
public final class LookAroundCoordinator {
    public static let shared = LookAroundCoordinator()

    // MARK: - Cache plumbing
    // Coordinates rounded to ~30 m so the same physical location resolves to
    // the same cache key even when the user's GPS ping drifts a few meters.
    private struct CellKey: Hashable {
        let lat: Int32
        let lon: Int32
        init(_ coord: CLLocationCoordinate2D) {
            // ~30 m in latitude ≈ 0.00027° (~30 m at 33°N)
            // ~30 m in longitude at 33°N ≈ 0.00035°
            // Using 3 decimal places is ~110 m — coarser than ideal. Use 4 for tighter.
            self.lat = Int32((coord.latitude  * 10000.0).rounded())
            self.lon = Int32((coord.longitude * 10000.0).rounded())
        }
    }

    private var cache: [CellKey: MKLookAroundScene] = [:]
    private let cacheLimit = 32
    private var insertionOrder: [CellKey] = []

    // In-flight task so callers can cancel / ignore stale results.
    private var currentTask: Task<MKLookAroundScene?, Never>?

    private init() {}

    /// Cancels any in-flight request and starts a fresh one. Result is cached
    /// so a second call within the same ~30 m cell is instant.
    public func requestScene(at coordinate: CLLocationCoordinate2D) async -> MKLookAroundScene? {
        let key = CellKey(coordinate)
        if let cached = cache[key] {
            return cached
        }

        // Cancel previous in-flight (we only care about the latest target).
        currentTask?.cancel()

        let task = Task<MKLookAroundScene?, Never> { [coordinate] in
            guard #available(iOS 16.0, *) else { return nil }
            let request = MKLookAroundSceneRequest(coordinate: coordinate)
            do {
                let scene = try await request.scene
                if Task.isCancelled { return nil }
                return scene
            } catch {
                // Apple returns no scene when Look Around isn't available at
                // the coordinate (suburban, no coverage). That's expected.
                return nil
            }
        }
        currentTask = task

        let scene = await task.value
        if let scene {
            store(scene, for: key)
        }
        return scene
    }

    /// Drops every cached scene. Call this on `endNavigation()` / `endSession()`
    /// to free memory between drives.
    public func clear() {
        cache.removeAll()
        insertionOrder.removeAll()
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - Cache bookkeeping

    private func store(_ scene: MKLookAroundScene, for key: CellKey) {
        if cache[key] == nil {
            insertionOrder.append(key)
        }
        cache[key] = scene

        // LRU: drop oldest entries beyond the limit.
        while insertionOrder.count > cacheLimit {
            let oldest = insertionOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }
}
