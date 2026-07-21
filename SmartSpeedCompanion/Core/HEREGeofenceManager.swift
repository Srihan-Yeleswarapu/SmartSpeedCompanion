// HEREGeofenceManager.swift
// Monitors the user's location and triggers background batch fetches when
// the user enters an area that has no cached road data in the SQLite cache.
//
// ARCHITECTURE
// ─────────────
// The manager observes GPS location updates. On each significant movement
// (>100m from last check point), it queries the SQLite cache to see if any
// road segments are cached within 100m of the user. If not, it triggers a
// background batch fetch via HERERouteMatchingBatchProvider to pre-populate
// the cache for the area.
//
// The batch results (road_name, direction, speed_limit, lat, lon) are stored
// directly in the SQLite cache. SpeedLimitService then looks them up by road
// name + direction (fast path) or by spatial nearest-neighbor (fallback).
//
// This ensures the user never waits for a speed limit — if the batch cache
// misses, the live provider chain (HERE REST → ArcGIS → Overpass) serves
// as an immediate fallback while the batch fetch runs in the background.

import Foundation
import CoreLocation
import Combine

/// Monitors location and triggers batch fetches for uncached areas.
@MainActor
public final class HEREGeofenceManager: ObservableObject {
    public static let shared = HEREGeofenceManager()

    // ── Published ────────────────────────────────────────────────────

    /// True while a batch fetch is in progress.
    @Published public private(set) var isFetching: Bool = false
    /// Estimated percentage of the local area that is cached (0–100).
    @Published public private(set) var estimatedCoveragePercent: Int = 0

    /// Emits when a new batch fetch completes successfully (count of new roads cached).
    public let didCompleteBatchFetch = PassthroughSubject<Int, Never>()

    // ── Dependencies ─────────────────────────────────────────────────

    private let batchProvider = HERERouteMatchingBatchProvider()
    /// The real LocationManager is injected via configure(). This is a placeholder.
    private let locationManager: LocationManager

    // ── State ────────────────────────────────────────────────────────

    /// Last GPS coordinate we ran a cache check at. Only re-check when the
    /// user moves more than `recheckDistanceMeters` from this point.
    private var lastCheckCoordinate: CLLocationCoordinate2D?
    /// Minimum distance the user must travel before we re-check the cache.
    private let recheckDistanceMeters: Double = 100
    /// Radius to query the cache for existing data (100m).
    private let cacheCheckRadiusMeters: Double = 100

    private var cancellables = Set<AnyCancellable>()

    private init() {
        self.locationManager = LocationManager()
    }

    /// Initialize the manager with a reference to the app's LocationManager.
    /// Call this after LocationManager is created (e.g., from App init or SpeedEngine).
    public func configure(locationManager: LocationManager) {
        // Observe location updates
        locationManager.$latestLocation
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] location in
                self?.onLocationUpdate(location.coordinate)
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    /// Manually trigger a batch refresh for the user's current area.
    /// Returns the number of new road segments cached.
    @discardableResult
    public func manualRefresh(around coordinate: CLLocationCoordinate2D) async -> Int {
        isFetching = true
        defer { isFetching = false }

        do {
            let count = try await batchProvider.fetchAndCacheGrid(around: coordinate)
            if count > 0 {
                didCompleteBatchFetch.send(count)
                lastCheckCoordinate = coordinate
            }
            updateCoverage(at: coordinate)
            return count
        } catch {
            DebugLogger.shared.log("HEREGeofence: manual refresh failed: \(error.localizedDescription)")
            return 0
        }
    }

    /// Trigger the initial setup batch — called once when the user first
    /// starts driving (on first valid GPS tick). Wider radius (2.5km) and
    /// no throttle to build the initial cache quickly.
    @discardableResult
    public func performInitialSetup(around coordinate: CLLocationCoordinate2D) async -> Int {
        isFetching = true
        defer { isFetching = false }

        do {
            // Wider radius for initial coverage
            let count = try await batchProvider.fetchAndCacheGrid(
                around: coordinate,
                radiusMeters: 2500
            )
            if count > 0 {
                didCompleteBatchFetch.send(count)
                lastCheckCoordinate = coordinate
            }
            updateCoverage(at: coordinate)
            DebugLogger.shared.log("HEREGeofence: initial setup cached \(count) road segments")
            return count
        } catch {
            DebugLogger.shared.log("HEREGeofence: initial setup failed: \(error.localizedDescription)")
            return 0
        }
    }

    // MARK: - Location Monitoring

    /// Called on every GPS tick. Checks if the user has moved significantly
    /// from the last cache check point. If so, queries the SQLite cache for
    /// nearby data. Triggers a background batch fetch if the area is uncached.
    private func onLocationUpdate(_ coordinate: CLLocationCoordinate2D) {
        // Only re-check when the user moves beyond the threshold.
        if let last = lastCheckCoordinate {
            let loc1 = CLLocation(latitude: last.latitude, longitude: last.longitude)
            let loc2 = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            guard loc1.distance(from: loc2) >= recheckDistanceMeters else { return }
        }
        // Guard against starting a second batch fetch while one is already
        // in-flight. The user would need to travel 100m during a ~1-2 second
        // network request for this to matter, but it prevents pile-up.
        guard !isFetching else { return }

        lastCheckCoordinate = coordinate

        // Query the SQLite cache: are there any cached roads within 100m?
        Task { @MainActor in
            let isCached = HERELocalBatchCache.shared.isAreaCached(
                coordinate: coordinate,
                radiusMeters: cacheCheckRadiusMeters
            )

            if isCached {
                // Area is already cached — just update coverage and return.
                updateCoverage(at: coordinate)
                return
            }

            // Not cached. Trigger a background batch fetch.
            DebugLogger.shared.log("HEREGeofence: uncached area — triggering background batch fetch")
            isFetching = true

            do {
                let count = try await batchProvider.fetchAndCacheGrid(around: coordinate)
                if count > 0 {
                    didCompleteBatchFetch.send(count)
                }
            } catch {
                DebugLogger.shared.log("HEREGeofence: background fetch failed: \(error.localizedDescription)")
            }

            isFetching = false
            updateCoverage(at: coordinate)
        }
    }

    // MARK: - Coverage Estimation

    /// Update the estimated coverage percentage by checking 4 concentric
    /// rings around the coordinate.
    private func updateCoverage(at coordinate: CLLocationCoordinate2D) {
        let coverage = HERELocalBatchCache.shared.estimatedCoverage(
            at: coordinate,
            radiusMeters: 1500
        )
        estimatedCoveragePercent = Int(coverage * 100)
    }
}
