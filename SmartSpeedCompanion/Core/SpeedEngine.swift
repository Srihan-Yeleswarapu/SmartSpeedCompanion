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
        let currentSpeed = max(0, location.speed * 2.23694)
        self.speed = currentSpeed
        
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
