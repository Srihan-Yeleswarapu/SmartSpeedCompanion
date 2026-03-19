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
    
    /// Minimum distance (meters) the user must travel before we re-query the speed limit DB.
    /// 15m keeps the display snappy without hammering the DB on every GPS tick.
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
        let conversionFactor = isMetric ? 3.6 : 2.23694 // m/s to km/h or mph

        // Use raw GPS speed directly — do not add a manual offset.
        // GPS chips already account for Doppler shift and the offset caused discrepancies.
        let rawSpeed = location.speed * conversionFactor
        let currentSpeed = max(0, rawSpeed)
        
        self.speed = currentSpeed
        
        // Update status immediately with cache
        updateStatus(speed: currentSpeed, limit: Double(self.limit))
        
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
            let currentMph = isMetric ? currentSpeed * 0.621371 : currentSpeed

            // 3. The Corrected Call
            do {
                let currentLimit = try await speedLimitService.updateSpeedLimit(
                    at: location.coordinate,
                    heading: carHeading,
                    currentSpeedMph: currentMph
                )
                self.limit = currentLimit
            } catch {
                // If no road is found, we set limit to 0 to show "???" 
                // or keep the last known limit depending on your preference.
                self.limit = 0 
                DebugLogger.shared.log("SpeedEngine: No limit found for this coordinate.")
            }
            
            updateStatus(speed: currentSpeed, limit: Double(self.limit))
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