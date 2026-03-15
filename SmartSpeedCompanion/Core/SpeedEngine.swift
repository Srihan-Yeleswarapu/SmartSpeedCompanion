import Foundation
import Combine
import CoreLocation
import SwiftUI // For @AppStorage

/// Engine responsible for observing location, determining speed, buffer, and calculating status.
@MainActor
public final class SpeedEngine: ObservableObject {
    @Published public var speed: Double = 0.0
    @Published public var limit: Int = 25
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
        
        // Apply user requested speed adjustments
        var adjustedSpeed = currentSpeed
        let speedMph = isMetric ? currentSpeed * 0.621371 : currentSpeed
        
        if speedMph > 35.0 {
            adjustedSpeed += (isMetric ? 3.21868 : 2.0) // 2 mph
        } else if speedMph >= 25.0 {
            adjustedSpeed += (isMetric ? 1.60934 : 1.0) // 1 mph
        }
        
        self.speed = adjustedSpeed
        
        // --- PERFORMANCE FIX: Update status IMMEDIATELY using current (cached) limit ---
        updateStatus(speed: adjustedSpeed, limit: Double(self.limit))
        
        Task { @MainActor in
            // Only query OSM/estimate if accuracy is good enough
            if location.horizontalAccuracy > 0 && location.horizontalAccuracy < 50 {
                let currentLimit = await speedLimitService.updateSpeedLimit(at: location.coordinate, currentSpeedMph: isMetric ? currentSpeed * 0.621371 : currentSpeed)
                
                // Convert fetched limit if needed (OSM/GeoJSON return MPH usually for this app's logic)
                // But let's assume limit is always in MPH internally and we convert for display if metric.
                // Wait, Arizona data is definitely MPH. OSM can be either. 
                // Let's keep self.limit as the raw fetched value (usually MPH) and convert in threshold check.
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
            if self.status != .over {
                DebugLogger.shared.log("STATUS CHANGE: OVER LIMIT (Speed: \(Int(speed)), Limit: \(Int(limit)))")
            }
            self.status = .over
        } else if speed > (threshold - (isMetric ? 3.0 : 2.0)) {
            if self.status != .warning {
                DebugLogger.shared.log("STATUS CHANGE: WARNING (Approaching limit)")
            }
            self.status = .warning
        } else {
            if self.status != .safe && self.status != .notDetermined {
                 DebugLogger.shared.log("STATUS CHANGE: SAFE")
            }
            self.status = .safe
        }
    }
}
