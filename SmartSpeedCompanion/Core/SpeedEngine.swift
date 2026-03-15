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

        let currentSpeed = max(0, location.speed * conversionFactor)
        self.speed = currentSpeed
        
        // Update status immediately with cache
        updateStatus(speed: currentSpeed, limit: Double(self.limit))
        
        Task { @MainActor in
            if location.horizontalAccuracy > 0 && location.horizontalAccuracy < 20 {
                // Pass heading (course) to ensure we only snap to roads running in our direction
                let carHeading = location.course >= 0 ? location.course : nil
                
                let currentLimit = await speedLimitService.updateSpeedLimit(
                    at: location.coordinate,
                    heading: carHeading,
                    currentSpeedMph: isMetric ? currentSpeed * 0.621371 : currentSpeed
                )
                
                self.limit = currentLimit
                updateStatus(speed: currentSpeed, limit: Double(currentLimit))
            }
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
        } else if speed > (threshold - (isMetric ? 3.0 : 2.0)) {
            self.status = .warning
        } else {
            self.status = .safe
        }
    }
}
