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
    private var cancellables = Set<AnyCancellable>()
    
    private var smoothedSpeed: Double = 0.0
    private let smoothingFactor: Double = 0.4 
    
    /// Minimum distance (meters) the user must travel before we re-query the speed limit DB.
    private let minimumFetchDistance: CLLocationDistance = 15.0
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
            
            // 2. Movement check
            if let lastLoc = lastFetchLocation,
            location.distance(from: lastLoc) < minimumFetchDistance {
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
                currentSpeedMph: currentMph
            )
            
            self.limit = currentLimit
            updateStatus(speed: self.speed, limit: Double(currentLimit))
        }
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