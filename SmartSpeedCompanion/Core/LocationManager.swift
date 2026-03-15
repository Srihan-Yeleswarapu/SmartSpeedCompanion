import Foundation
import CoreLocation
import Combine

/// A wrapper around CLLocationManager for high-accuracy GPS and navigation context.
public final class LocationManager: NSObject, ObservableObject {
    private let manager = CLLocationManager()
    
    @Published public var latestLocation: CLLocation?
    @Published public var latestHeading: CLHeading?
    @Published public var authorizationStatus: CLAuthorizationStatus = .notDetermined
    
    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.allowsBackgroundLocationUpdates = true // Requires 'location' in UIBackgroundModes
        manager.showsBackgroundLocationIndicator = true
        
        // Navigation-grade heading
        manager.headingFilter = 2.0 // Update every 2 degrees
        DebugLogger.shared.log("LocationManager initialized.")
    }
    
    /// Requests Always authorization, required for CarPlay background operation.
    public func requestAuthorization() {
        manager.requestAlwaysAuthorization()
        DebugLogger.shared.log("LocationManager: Requesting Always Authorization.")
    }
    
    public func startUpdatingLocation() {
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
        DebugLogger.shared.log("LocationManager: Started updating location and heading.")
    }
    
    public func stopUpdatingLocation() {
        manager.stopUpdatingLocation()
        DebugLogger.shared.log("LocationManager: Stopped updating location.")
    }
}

extension LocationManager: CLLocationManagerDelegate {
    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            self.authorizationStatus = manager.authorizationStatus
            DebugLogger.shared.log("LocationManager: Authorization status changed to \(manager.authorizationStatus.rawValue).")
        }
    }
    
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        DispatchQueue.main.async {
            self.latestLocation = location
            DebugLogger.shared.log("LocationManager: Did update location to [\(String(format: "%.4f", location.coordinate.latitude)), \(String(format: "%.4f", location.coordinate.longitude))].")
        }
    }
    
    public func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        DispatchQueue.main.async {
            self.latestHeading = newHeading
            DebugLogger.shared.log("LocationManager: Did update heading to \(String(format: "%.1f", newHeading.trueHeading)) degrees.")
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DebugLogger.shared.log("LocationManager ERROR: \(error.localizedDescription)")
        print("LocationManager failed with error: \(error.localizedDescription)")
    }
}
