import Foundation
import CoreLocation
import Combine

/// A wrapper around CLLocationManager for high-accuracy GPS and navigation context.
public final class LocationManager: NSObject, ObservableObject {
    private let manager = CLLocationManager()
    
    @Published public var latestLocation: CLLocation?
    @Published public var authorizationStatus: CLAuthorizationStatus = .notDetermined
    
    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.allowsBackgroundLocationUpdates = true // Requires 'location' in UIBackgroundModes
        manager.showsBackgroundLocationIndicator = true
    }
    
    /// Requests Always authorization, required for CarPlay background operation.
    public func requestAuthorization() {
        manager.requestAlwaysAuthorization()
    }
    
    public func startUpdatingLocation() {
        manager.startUpdatingLocation()
    }
    
    public func stopUpdatingLocation() {
        manager.stopUpdatingLocation()
    }
}

extension LocationManager: CLLocationManagerDelegate {
    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            self.authorizationStatus = manager.authorizationStatus
        }
    }
    
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        DispatchQueue.main.async {
            self.latestLocation = location
        }
        
        Task { @MainActor in
            if location.horizontalAccuracy > 0 && location.horizontalAccuracy < 50 {
                CrowdsourceSpeedLimitService.shared.onLocationUpdate(location.coordinate)
            }
        }
    }
    
    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("LocationManager failed with error: \(error.localizedDescription)")
    }
}
