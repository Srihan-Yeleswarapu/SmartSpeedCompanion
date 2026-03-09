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
    
    private let speedLimitService = SmartSpeedLimitService.shared
    private var cancellables = Set<AnyCancellable>()
    
    // For moving average smoothing
    private var speedHistory: [Double] = []
    
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
        // Convert m/s to mph: max(0, speed * 2.23694)
        var currentSpeed = max(0, location.speed * 2.23694)
        
        // Very low speeds often fluctuate due to GPS drift — clamp them
        if currentSpeed < 1.0 { currentSpeed = 0.0 }
        
        // Moving average (last 3 points)
        speedHistory.append(currentSpeed)
        if speedHistory.count > 3 {
            speedHistory.removeFirst()
        }
        
        let smoothedSpeed = speedHistory.reduce(0, +) / Double(speedHistory.count)
        self.speed = round(smoothedSpeed) // Round to nearest int for clean UI
        
        Task { @MainActor in
            // Only query OSM/estimate if accuracy is good enough
            if location.horizontalAccuracy > 0 && location.horizontalAccuracy < 50 {
                let currentLimit = await speedLimitService.updateSpeedLimit(at: location.coordinate, currentSpeedMph: currentSpeed)
                self.limit = currentLimit
            }
            
            let threshold = Double(self.limit + self.userBuffer)
            
            if currentSpeed > threshold {
                self.status = .over
            } else if currentSpeed > (threshold - 2.0) {
                self.status = .warning
            } else {
                self.status = .safe
            }
        }
    }
}
