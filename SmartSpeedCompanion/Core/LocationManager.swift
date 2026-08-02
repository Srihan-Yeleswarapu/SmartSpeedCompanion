import Foundation
import CoreLocation
import Combine

/// A wrapper around CLLocationManager for high-accuracy GPS and navigation context.
public final class LocationManager: NSObject, ObservableObject {
    private let manager = CLLocationManager()
    
    @Published public var latestLocation: CLLocation?
    @Published public var latestHeading: CLHeading?
    @Published public var authorizationStatus: CLAuthorizationStatus = .notDetermined
    
    #if DEBUG || DEVELOPER_BUILD
    @Published public var isMockMode: Bool = false
    private var mockCancellable: AnyCancellable?
    #endif
    
    public override init() {
        super.init()
        manager.delegate = self
        manager.distanceFilter = kCLDistanceFilterNone
        // Location is demand-driven: no GPS or background indicator is enabled
        // until a recording/navigation session explicitly starts. The app still
        // declares the location background mode because an active session must
        // continue safely while the phone is locked or the app is backgrounded.
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false

        // Navigation-grade heading
        manager.headingFilter = 2.0 // Update every 2 degrees

        // Apply user-selected GPS accuracy (set before starting updates)
        applyAccuracyMode()

        #if DEBUG || DEVELOPER_BUILD
        setupMockSubscription()
        // In the iOS Simulator there is no real GPS. Auto-engage mock mode
        // so the app is usable the moment the user hits Run. Real-device
        // users still start in non-mock mode and toggle from the Developer
        // tab. isMockMode defaults to false; we only flip it for simulator.
        #if targetEnvironment(simulator)
        self.isMockMode = true
        DebugLogger.shared.log("LocationManager: auto-engaged mock mode (iOS Simulator detected).")
        #endif
        #endif

        DebugLogger.shared.log("LocationManager initialized.")
    }
    
    #if DEBUG || DEVELOPER_BUILD
    private func setupMockSubscription() {
        mockCancellable = NotificationCenter.default.publisher(for: .didUpdateMockLocation)
            .compactMap { $0.object as? CLLocation }
            .sink { [weak self] location in
                guard let self = self, self.isMockMode else { return }
                DispatchQueue.main.async {
                    self.latestLocation = location
                }
            }
    }
    #endif
    
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
    
    /// Requests While-Using authorization, suitable for the first-launch
    /// permission prompt shown after the tutorial. Upgraded to Always later
    /// when the user starts a driving session (for CarPlay background ops).
    /// In the iOS Simulator the location-permission dialog is theatre
    /// (the mock-location path doesn't need it) and a "Don't Allow" tap
    /// silently breaks the flow. Skip the request entirely on simulator.
    public func requestWhenInUseAuthorization() {
        #if targetEnvironment(simulator)
        return
        #else
        manager.requestWhenInUseAuthorization()
        DebugLogger.shared.log("LocationManager: Requesting WhenInUse Authorization.")
        #endif
    }

    /// Requests Always authorization, required for CarPlay background operation.
    public func requestAuthorization() {
        // In the iOS Simulator the location-permission dialog is theatre
        // (the mock-location path doesn't need it) and a "Don't Allow" tap
        // silently breaks the flow. Skip the request entirely on simulator.
        #if targetEnvironment(simulator)
        return
        #else
        manager.requestAlwaysAuthorization()
        DebugLogger.shared.log("LocationManager: Requesting Always Authorization.")
        #endif
    }
    
    public func startUpdatingLocation() {
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
        DebugLogger.shared.log("LocationManager: Started updating location and heading.")
    }
    
    public func stopUpdatingLocation() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        DebugLogger.shared.log("LocationManager: Stopped updating location and heading.")
    }
    
    /// Dynamically enables or disables background location updates.
    /// Call with `true` when starting a session (so the Dynamic Island
    /// shows location during the drive), and `false` when ending a session
    /// (so the background indicator hides when not actively recording).
    /// Has no effect if location updates are not active.
    public func setBackgroundUpdates(_ enabled: Bool) {
        manager.allowsBackgroundLocationUpdates = enabled
        manager.showsBackgroundLocationIndicator = enabled
        DebugLogger.shared.log("LocationManager: Background updates \(enabled ? "ENABLED" : "DISABLED")")
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
        #if DEBUG || DEVELOPER_BUILD
        if isMockMode { return }
        #endif
        
        guard let location = locations.last else { return }
        // Filter out stale or wildly inaccurate fixes to prevent map-going-bonkers
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy < 100 else { return }
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