import Foundation
import Combine
import SwiftData

/// Main observable view model that combines LocationManager, SpeedEngine, AlertEngine, and SessionRecorder.
@MainActor
public final class DriveViewModel: ObservableObject {
    public let locationManager: LocationManager
    public let speedEngine: SpeedEngine
    public let alertEngine: AlertEngine
    public let sessionRecorder: SessionRecorder
    
    // Published properties reflecting the current state
    @Published public var speed: Double = 0.0
    @Published public var limit: Int = 0
    @Published public var status: SpeedStatus = .safe
    @Published public var isRecording: Bool = false
    @Published public var alertActive: Bool = false
    
    private var cancellables = Set<AnyCancellable>()
    
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
}
