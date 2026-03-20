#if DEBUG || DEVELOPER_BUILD
import Foundation
import CoreLocation
import Combine

/// A manager that handles manual override of GPS data for testing purposes.
public final class SimulationManager: ObservableObject {
    public static let shared = SimulationManager()
    
    @Published public var isSimulationActive = false {
        didSet {
            if isSimulationActive {
                startTimer()
            } else {
                stopTimer()
            }
        }
    }
    
    @Published public var mockCoordinate = CLLocationCoordinate2D(latitude: 33.4484, longitude: -112.0740) // Default: Phoenix, AZ
    @Published public var mockHeading: Double = 0.0
    @Published public var mockSpeed: Double = 0.0 // mph
    
    private var timer: AnyCancellable?
    
    private init() {}
    
    private func startTimer() {
        timer?.cancel()
        timer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.broadcastMockLocation()
            }
    }
    
    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }
    
    /// Broadcasts a new CLLocation object based on the current mock state.
    private func broadcastMockLocation() {
        // speed in CLLocation is in meters per second
        let speedInMs = mockSpeed / 2.23694
        
        let location = CLLocation(
            coordinate: mockCoordinate,
            altitude: 0,
            horizontalAccuracy: 5.0, // Good accuracy to pass engine filters
            verticalAccuracy: 5.0,
            course: mockHeading,
            speed: speedInMs,
            timestamp: Date()
        )
        
        // Post notification so LocationManager can intercept if in mock mode
        NotificationCenter.default.post(name: .didUpdateMockLocation, object: location)
    }
}

extension Notification.Name {
    public static let didUpdateMockLocation = Notification.Name("didUpdateMockLocation")
}
#endif
