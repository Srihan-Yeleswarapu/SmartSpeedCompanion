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
        manager.distanceFilter = kCLDistanceFilterNone
        manager.allowsBackgroundLocationUpdates = true // Requires 'location' in UIBackgroundModes
        manager.showsBackgroundLocationIndicator = true
        
        // Navigation-grade heading
        manager.headingFilter = 2.0 // Update every 2 degrees
        
        // Apply user-selected GPS accuracy (set before starting updates)
        applyAccuracyMode()
        DebugLogger.shared.log("LocationManager initialized.")
    }
    
    /// Applies the current gpsAccuracyMode preference from UserDefaults.
    /// Call this any time the user changes the accuracy setting.
    public func applyAccuracyMode() {
        let mode = UserDefaults.standard.string(forKey: "gpsAccuracyMode") ?? "navigation"
        if mode == "balanced" {
            // Balanced: saves battery / heat at the cost of ~5-10m accuracy
            manager.desiredAccuracy = kCLLocationAccuracyBest
            DebugLogger.shared.log("LocationManager: Accuracy set to BALANCED (Best)")
        } else {
            // Default: full navigation-grade accuracy
            manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            DebugLogger.shared.log("LocationManager: Accuracy set to NAVIGATION (BestForNavigation)")
        }
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
        // Filter out stale or wildly inaccurate fixes to prevent map-going-bonkers
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy < 200 else { return }
        DispatchQueue.main.async {
            self.latestLocation = location
            // NOTE: Per-update coordinate logging removed to reduce heat from constant 
            // log-flush I/O on devices processing ~1 GPS update per second.
        }
    }
    
    public func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        DispatchQueue.main.async {
            self.latestHeading = newHeading
            // Heading updates fire continuously while driving — avoid logging here to prevent heat
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DebugLogger.shared.log("LocationManager ERROR: \(error.localizedDescription)")
        print("LocationManager failed with error: \(error.localizedDescription)")
    }
}