import Foundation
import Combine
import CoreLocation
import SwiftUI // For @AppStorage

/// Engine responsible for observing location, determining speed, buffer, and calculating status.
@MainActor
public final class SpeedEngine: ObservableObject {
    @Published public var speed: Double = 0.0
    @Published public var limit: Int = 0
    @Published public var status: SpeedStatus = .safe
    
    @AppStorage("userBuffer") public var userBuffer: Int = 5 // 0 to 15 mph
    @AppStorage("measurementSystem") public var measurementSystem: String = "Imperial"
    
    private let speedLimitService = SmartSpeedLimitService.shared
    private let roadGeocoder = RoadGeocoder.shared
    private var cancellables = Set<AnyCancellable>()

    private var smoothedSpeed: Double = 0.0
    private let smoothingFactor: Double = 0.4    // No own throttle on road-name resolution. `RoadGeocoder` carries its
    // own 50m grid-cell cache (see SmartSpeedCompanion/Core/RoadGeocoder.swift)
    // so a typical city drive costs ~1 geocode per block instead of per 1-Hz
    // GPS ping, AND the cached road name is preserved across the 50m cells so
    // the name-match bonus in ArizonaSpeedLimitService keeps firing.

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
        
        // Apply EMA filter: Smoothed = (New * Alpha) + (Old * (1 - Alpha))
        // This eliminates the jitter users see during steady cruising.
        if smoothedSpeed == 0 && rawSpeedMph > 0 {
            smoothedSpeed = rawSpeedMph
        } else {
            smoothedSpeed = (rawSpeedMph * smoothingFactor) + (smoothedSpeed * (1.0 - smoothingFactor))
        }
        
        // 3. Status Update and Display
        let displaySpeed = isMetric ? smoothedSpeed * 1.60934 : smoothedSpeed
        let finalSpeed = max(0, displaySpeed)
        
        self.speed = finalSpeed
        
        // Update status immediately
        updateStatus(speed: finalSpeed, limit: Double(self.limit))
        
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