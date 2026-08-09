import Foundation
import Combine
import CoreLocation
import SwiftUI // For @AppStorage

/// Engine responsible for observing location, determining speed, buffer, and calculating status.
@MainActor
public final class SpeedEngine: ObservableObject {
    @Published public var speed: Double = 0.0
    @Published public var limit: Int = 0
    /// True only after the latest requested lookup produced a usable posted
    /// limit. AlertEngine uses this separately from `limit` so an old value
    /// cannot keep beeping while a new lookup is in flight.
    @Published public private(set) var isLimitResolved: Bool = false
    @Published public var status: SpeedStatus = .safe
    
    @AppStorage("userBuffer") public var userBuffer: Int = 5 // -5 to 15 mph
    @AppStorage("measurementSystem") public var measurementSystem: String = "Imperial"
    
    private let locationManager: LocationManager
    private let speedLimitService = SmartSpeedLimitService.shared
    private let roadGeocoder = RoadGeocoder.shared
    private var cancellables = Set<AnyCancellable>()

    private var smoothedSpeed: Double = 0.0
    private let smoothingFactor: Double = 0.15

    // ── Zero-speed deadband ──────────────────────────────────
    /// Number of consecutive raw readings that must fall below the
    /// `minSpeedThreshold` before we force the displayed speed to zero.
    /// Prevents GPS noise from showing "5 mph" while the user is
    /// stationary (holding the phone, sitting at a red light, etc.).
    private var zeroDeadbandCount: Int = 0
    private let minZerosBeforeStop: Int = 5
    /// Raw speed (mph) below which we count toward the deadband.
    private let minSpeedThreshold: Double = 3.0
    /// Raw speed (mph) below which we force the display to exactly 0.
    private let forceZeroThreshold: Double = 0.8

    /// Fires the initial HERE batch cache setup once when the first valid,
    /// accurate GPS location arrives. After the first trigger, this flag
    /// is set so it never fires again.
    private var hasFiredInitialSetup: Bool = false

    // No own throttle on road-name resolution. `RoadGeocoder` carries its
    // own 50m grid-cell cache (see SmartSpeedCompanion/Core/RoadGeocoder.swift)
    // so a typical city drive costs ~1 geocode per block instead of per 1-Hz
    // GPS ping. The cached road name is preserved across the 50m cells so
    // live providers receive consistent road context on every fetch.

    /// Minimum distance (meters) the user must travel before we re-query the speed limit provider.
    /// The orchestration now self-throttles via the SpeedLimitResponseCache (spatial-grid
    /// short-circuit) + per-provider dedup, so we can space out fetches far enough for the
    /// live network providers without missing turns on city streets.
    ///   - Surface streets (< 20 m/s = ~45 mph): 80m (~ one city block)
    ///   - Highways (>= 20 m/s): 250m
    private let surfaceFetchDistance: CLLocationDistance = 80.0
    private let highwayFetchDistance: CLLocationDistance = 250.0
    private var lastFetchLocation: CLLocation?
    
    public init(locationManager: LocationManager) {
        self.locationManager = locationManager
        locationManager.$latestLocation
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] location in
                self?.processLocation(location)
            }
            .store(in: &cancellables)
    }
    
    private func processLocation(_ location: CLLocation) {
        let isMetric = measurementSystem == "Metric"
        
        // 1. Validation & Quality Filtering
        // If GPS returns -1 speed (invalid) or accuracy is extremely poor (>10m/s), 
        // we skip the update to prevent beeping from jitter.
        guard location.speed >= 0 else { return }
        
        // Use speedAccuracy if available
        if location.speedAccuracy >= 0 && location.speedAccuracy > 5.0 {
            // If GPS is reporting +/- 11 mph of uncertainty, it's too noisy for live display
            return
        }

        // 2. Conversion and Smoothing
        // Use m/s to mph as the base internal unit for smoothing
        let rawSpeedMph = location.speed * 2.23694

        // ── Zero-speed deadband ────────────────────────────────
        // If GPS says we're barely moving, accumulate a deadband counter.
        // Once enough consecutive sub-threshold readings stack up, force
        // the displayed speed to 0 — this kills the "phone on desk shows
        // 5 mph" noise.  We do NOT return early; the speed-limit Task
        // below must still run for initial HERE setup and limit fetching.
        if rawSpeedMph < minSpeedThreshold {
            zeroDeadbandCount += 1
        } else {
            zeroDeadbandCount = 0
        }

        if rawSpeedMph < forceZeroThreshold || zeroDeadbandCount >= minZerosBeforeStop {
            // Clamp display to zero without early-returning
            smoothedSpeed = 0
            zeroDeadbandCount = minZerosBeforeStop
            self.speed = 0
            self.status = .safe
        } else {
            // Apply EMA filter: Smoothed = (New × Alpha) + (Old × (1 − Alpha))
            // The lower factor (0.15 vs the old 0.4) aggressively dampens
            // GPS noise spikes without feeling sluggish on acceleration
            // because the raw input is still blended at 1 Hz.
            if smoothedSpeed == 0 && rawSpeedMph > 0 {
                // First movement — seed with a damped start
                smoothedSpeed = rawSpeedMph * 0.5
            } else {
                smoothedSpeed = (rawSpeedMph * smoothingFactor) + (smoothedSpeed * (1.0 - smoothingFactor))
            }

            let displaySpeed = isMetric ? smoothedSpeed * 1.60934 : smoothedSpeed
            let finalSpeed = max(0, displaySpeed)
            self.speed = finalSpeed
            updateStatus(speed: finalSpeed, limit: Double(self.limit))
        }

        // ── Speed-limit & initial-setup Task block always runs ──
        
        Task { @MainActor in
            // 1. Accurate GPS check
            guard location.horizontalAccuracy > 0 && location.horizontalAccuracy <= 15 else {
                return
            }
            
            // 2. Movement check — dynamic interval: 80m on surface streets, 250m on highways.
            let threshold: CLLocationDistance = location.speed >= 20 ? highwayFetchDistance : surfaceFetchDistance
            if let lastLoc = lastFetchLocation,
            location.distance(from: lastLoc) < threshold {
                return
            }
            lastFetchLocation = location
            // The previous answer is no longer authoritative while this
            // location is being resolved. This immediately stops an old
            // overspeed alert instead of allowing it to fire during the
            // network/provider wait.
            // SpeedEngine is the single source of truth for the limit shown
            // by the HUD and for alert eligibility. Clear the old value before
            // the async HERE lookup so a stale limit can never remain paired
            // with a new location while the UI already shows No Data.
            self.limit = 0
            self.isLimitResolved = false
            self.status = .safe

            // ── Initial HERE batch cache setup ───────────────────
            // Fire once on the first valid GPS tick to populate the
            // local batch cache with speed limits from a 2.5km grid.
            if !hasFiredInitialSetup {
                hasFiredInitialSetup = true
                Task {
                    // Fire initial batch cache setup to populate the
                    // local cache with speed limits for a ~2.5km grid.
                    await HEREGeofenceManager.shared.performInitialSetup(
                        around: location.coordinate
                    )
                    // Start geofence monitoring for just-in-time batch
                    // fetches when driving into uncached areas.
                    HEREGeofenceManager.shared.configure(
                        locationManager: self.locationManager
                    )
                }
            }

            let carHeading = location.course >= 0 ? location.course : nil
            let currentMph = isMetric ? self.speed * 0.621371 : self.speed

            // 3. The Corrected Call
            // No 'try' or 'do-catch' needed anymore
            let currentLimit = await speedLimitService.updateSpeedLimit(
                at: location.coordinate,
                heading: carHeading,
                currentSpeedMph: currentMph,
                roadName: await resolvedRoadName(at: location.coordinate)
            )

            self.limit = currentLimit
            self.isLimitResolved = currentLimit > 0
            updateStatus(speed: self.speed, limit: Double(currentLimit))
        }
    }

    /// Returns the cached or freshly-resolved road name from `RoadGeocoder`
    /// for the current coordinate.
    ///
    /// Implementation note: do NOT add a local throttle here. The previous
    /// implementation short-circuited with `return nil` when the caller was
    /// within 200m of the last geocode, which stripped the road name from
    /// the SpeedLimit pipeline for entire city blocks and caused the snap
    /// to fall back to spatial-only scoring -- which on roads like Arizona
    /// Avenue in Chandler returns S 202's 65 mph mega-bbox instead of the
    /// correct local-road answer. `RoadGeocoder` already throttles via its
    /// own 50m grid cache; this method just delegates so the road name
    /// flows through every fetch.
    private func resolvedRoadName(at coordinate: CLLocationCoordinate2D) async -> String? {
        return await roadGeocoder.resolveRoadContext(at: coordinate)?.roadName
    }
    
    /// Marks the current limit as unresolved before a direct/manual lookup.
    /// DriveViewModel uses this when it asks SmartSpeedLimitService outside
    /// the normal GPS-resolution task.
    public func beginLimitResolution() {
        // Clear the displayed limit immediately. Manual and heading-triggered
        // refreshes must have the same unknown-limit semantics as GPS refreshes:
        // neutral HUD, no red state, and no alert audio/haptics while HERE is
        // resolving the new road.
        limit = 0
        isLimitResolved = false
        status = .safe
    }

    /// Applies a limit returned by a direct lookup (manual refresh or a
    /// heading-triggered fetch) through the same state path as GPS updates.
    public func applyResolvedLimit(_ newLimit: Int) {
        limit = newLimit
        isLimitResolved = newLimit > 0
        updateStatus(speed: speed, limit: Double(newLimit))
    }

    private func updateStatus(speed: Double, limit: Double) {
        guard limit > 0 else {
            self.status = .safe
            return
        }
        
        let isMetric = measurementSystem == "Metric"
        let displayLimit = isMetric ? limit * 1.60934 : limit
        let displayBuffer = isMetric ? Double(userBuffer) * 1.60934 : Double(userBuffer)
        
        let threshold = displayLimit + displayBuffer
        
        if speed > threshold {
            self.status = .over
        } else if speed >= (threshold - (isMetric ? 2.0 : 1.0)) {
            self.status = .warning // Yellow only for the top 1 mph of buffer
        } else {
            self.status = .safe
        }
    }
}