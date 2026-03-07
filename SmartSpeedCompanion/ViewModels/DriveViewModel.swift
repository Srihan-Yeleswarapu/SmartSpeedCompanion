import Foundation
import Combine
import SwiftData
import MapKit

/// Main observable view model that combines LocationManager, SpeedEngine, AlertEngine, and SessionRecorder.
@MainActor
public final class DriveViewModel: ObservableObject {
    public let locationManager: LocationManager
    public let speedEngine: SpeedEngine
    public let alertEngine: AlertEngine
    public let sessionRecorder: SessionRecorder
    
    // Core driving state
    @Published public var speed: Double = 0.0
    @Published public var limit: Int = 0
    @Published public var status: SpeedStatus = .safe
    @Published public var isRecording: Bool = false
    @Published public var alertActive: Bool = false
    
    // Navigation state
    @Published public var isNavigating: Bool = false
    @Published public var currentRoute: MKRoute? = nil
    @Published public var destination: MKMapItem? = nil
    @Published public var nextManeuverInstruction: String = ""
    @Published public var distanceToNextTurn: CLLocationDistance = 0
    @Published public var eta: Date? = nil
    @Published public var speedLimitSource: String = "Estimating..."
    
    private var cancellables = Set<AnyCancellable>()
    // A weak reference or delegate will handle actual logic in CarPlay layer
    public var navigationDelegate: NavigationActionDelegate?
    
    public init(modelContext: ModelContext? = nil) {
        let locManager = LocationManager()
        let spdEngine = SpeedEngine(locationManager: locManager)
        let alrtEngine = AlertEngine(speedEngine: spdEngine)
        let rec = SessionRecorder(speedEngine: spdEngine, locationManager: locManager)
        
        if let ctx = modelContext {
            rec.setModelContext(ctx)
        }
        
        self.locationManager = locManager
        self.speedEngine = spdEngine
        self.alertEngine = alrtEngine
        self.sessionRecorder = rec
        
        // Bind UI state
        spdEngine.$speed.assign(to: &$speed)
        spdEngine.$limit.assign(to: &$limit)
        spdEngine.$status.assign(to: &$status)
        alrtEngine.$audioAlertActive.assign(to: &$alertActive)
        rec.$isRecording.assign(to: &$isRecording)
        
        // Bind Data Source
        SmartSpeedLimitService.shared.$dataSource
            .receive(on: RunLoop.main)
            .assign(to: &$speedLimitSource)
        
        // Request Location Authorization
        locManager.requestAuthorization()
        locManager.startUpdatingLocation()
    }
    
    public func startSession() {
        sessionRecorder.startSession()
    }
    
    public func endSession() {
        _ = sessionRecorder.endSession()
    }
    
    // Navigation controls  
    public func startNavigation(to destination: MKMapItem) async {
        await navigationDelegate?.startNavigationTrigger(to: destination)
    }
    
    public func endNavigation() {
        navigationDelegate?.endNavigationTrigger()
    }
    
    public func searchDestination(_ query: String) async -> [MKMapItem] {
        return await navigationDelegate?.searchDestinationTrigger(query) ?? []
    }
}

public protocol NavigationActionDelegate: AnyObject {
    func startNavigationTrigger(to destination: MKMapItem) async
    func endNavigationTrigger()
    func searchDestinationTrigger(_ query: String) async -> [MKMapItem]
}
