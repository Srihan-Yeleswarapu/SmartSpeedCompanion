#if DEBUG || DEVELOPER_BUILD
import Foundation
import CoreLocation
import Combine

/// Protocol to provide navigation data to the simulator for road-snapping.
public protocol SimulationDataSource: AnyObject {
    func getNearestPointOnRoute(to coordinate: CLLocationCoordinate2D) -> (coordinate: CLLocationCoordinate2D, heading: Double?)
}

/// A manager that handles manual override of GPS data for testing purposes.
public final class SimulationManager: ObservableObject {
    public static let shared = SimulationManager()
    
    public weak var dataSource: SimulationDataSource?
    
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
        if isSimulationActive {
            updateMockLocationPhysics()
        }
        
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
    
    private func updateMockLocationPhysics() {
        // Move forward based on heading and speed
        // 1 mph = 0.44704 m/s
        let speedInMs = mockSpeed * 0.44704
        let distanceMoving = speedInMs * 1.0 // 1 second tick
        
        if distanceMoving <= 0 { return }
        
        let earthRadius = 6378137.0 // meters
        let radiansHeading = mockHeading * .pi / 180.0
        
        let dLat = (distanceMoving * cos(radiansHeading)) / earthRadius
        let dLon = (distanceMoving * sin(radiansHeading)) / (earthRadius * cos(mockCoordinate.latitude * .pi / 180.0))
        
        var newLat = mockCoordinate.latitude + (dLat * 180.0 / .pi)
        var newLon = mockCoordinate.longitude + (dLon * 180.0 / .pi)
        var newCoord = CLLocationCoordinate2D(latitude: newLat, longitude: newLon)
        
        // ROAD SNAPPING: If we have a data source (e.g. active route), snap to it
        if let snapped = dataSource?.getNearestPointOnRoute(to: newCoord) {
            newCoord = snapped.coordinate
            // If the road has a defined heading, we can optionally inherit it 
            // but usually we want the user to control it unless it's "Auto-Drive"
            if let roadHeading = snapped.heading {
                // Smoothly merge current heading towards road heading if simulation is active
                // This gives that "follow the road" feel without taking total control.
                self.mockHeading = roadHeading 
            }
        }
        
        self.mockCoordinate = newCoord
    }
}

extension Notification.Name {
    public static let didUpdateMockLocation = Notification.Name("didUpdateMockLocation")
}
#endif
