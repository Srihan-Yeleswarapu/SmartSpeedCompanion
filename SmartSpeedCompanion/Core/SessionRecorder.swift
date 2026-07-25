import Foundation
import SwiftData
import CoreLocation

/// Records the drive session by capturing GPS data points every second.
@MainActor
public final class SessionRecorder: ObservableObject {
    @Published public var isRecording = false
    public var currentSession: DriveSession?
    
    private var modelContext: ModelContext?
    private let speedEngine: SpeedEngine
    private let locationManager: LocationManager
    private var recordingTimer: Timer?
    /// Periodic timer that saves current readings to SwiftData every 30 seconds
    /// so session data survives app termination mid-drive.
    private var checkpointTimer: Timer?
    
    public init(speedEngine: SpeedEngine, locationManager: LocationManager) {
        self.speedEngine = speedEngine
        self.locationManager = locationManager
    }
    
    public func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }
    
    public func startSession(destinationPlaceID: String? = nil) {
        guard !isRecording else { return }
        
        let newSession = DriveSession(startTime: .now)
        newSession.destinationPlaceID = destinationPlaceID
        currentSession = newSession
        isRecording = true
        
        if let location = locationManager.latestLocation {
            geocodeLocation(location) { (name: String?) in
                newSession.startLocationName = name
            }
        }
        
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recordDataPoint()
            }
        }
        
        // Start a checkpoint timer that persists readings every 30 seconds.
        // If the app terminates mid-drive, the partial session can be restored
        // from SwiftData on relaunch.
        startCheckpointTimer()
    }
    
    public func endSession() -> DriveSession? {
        guard isRecording, let session = currentSession else { return nil }
        
        recordingTimer?.invalidate()
        recordingTimer = nil
        checkpointTimer?.invalidate()
        checkpointTimer = nil
        isRecording = false
        
        session.endTime = .now
        
        // Save final checkpoint before clearing state
        persistCheckpoint()
        clearSavedSessionState()
        
        let completedSession = session
        currentSession = nil
        
        if let location = locationManager.latestLocation {
            geocodeLocation(location) { (name: String?) in
                completedSession.endLocationName = name
            }
        }
        
        return completedSession
    }
    
    // MARK: - Periodic Checkpointing
    
    /// Starts a 30-second repeating timer that snapshots current session
    /// readings into SwiftData so partial data survives app termination.
    private func startCheckpointTimer() {
        checkpointTimer?.invalidate()
        checkpointTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.persistCheckpoint()
            }
        }
    }
    
    /// Saves the current session's readings to SwiftData as a checkpoint.
    /// If the app terminates mid-drive, the partially-recorded session can
    /// be retrieved from the store.
    private func persistCheckpoint() {
        guard let session = currentSession, let context = modelContext else { return }
        context.insert(session)
        do {
            try context.save()
            DebugLogger.shared.log("SessionRecorder: checkpoint saved (\(session.readings.count) readings)")
        } catch {
            DebugLogger.shared.log("SessionRecorder: checkpoint save failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Session State Persistence (App Termination Survival)
    
    /// Persists a lightweight snapshot of the current session to UserDefaults
    /// so the app can detect an interrupted drive on relaunch. Call this when
    /// the app enters the background.
    public func saveSessionState() {
        guard let session = currentSession else {
            clearSavedSessionState()
            return
        }
        let ud = UserDefaults.standard
        ud.set(true, forKey: "sessionRecorder_isRecording")
        ud.set(session.startTime, forKey: "sessionRecorder_sessionStartTime")
        if let placeID = session.destinationPlaceID {
            ud.set(placeID, forKey: "sessionRecorder_destinationPlaceID")
        }
        DebugLogger.shared.log("SessionRecorder: saved session state to UserDefaults")
    }
    
    /// Clears the session state keys from UserDefaults.
    public func clearSavedSessionState() {
        let ud = UserDefaults.standard
        ud.removeObject(forKey: "sessionRecorder_isRecording")
        ud.removeObject(forKey: "sessionRecorder_sessionStartTime")
        ud.removeObject(forKey: "sessionRecorder_destinationPlaceID")
        DebugLogger.shared.log("SessionRecorder: cleared saved session state")
    }
    
    /// Checks UserDefaults for an interrupted session.
    public static func hasInterruptedSession() -> Bool {
        UserDefaults.standard.bool(forKey: "sessionRecorder_isRecording")
    }
    
    /// Returns the start time of an interrupted session from UserDefaults.
    public static func interruptedSessionStartTime() -> Date? {
        UserDefaults.standard.object(forKey: "sessionRecorder_sessionStartTime") as? Date
    }
    
    /// Returns the destination place ID of an interrupted session.
    public static func interruptedSessionDestinationPlaceID() -> String? {
        UserDefaults.standard.string(forKey: "sessionRecorder_destinationPlaceID")
    }
    
    public func saveSession(_ session: DriveSession) {
        // Capture context reference synchronously to avoid race condition with later setModelContext calls
        // The [context] capture list ensures we use the same context instance that was validated
        guard let context = modelContext else {
            DebugLogger.shared.log("SessionRecorder: Cannot save - ModelContext not configured")
            return
        }
        
        // Ensure ModelContext operations happen on MainActor (SwiftData requirement)
        // Using [context] capture list to bind the validated context value
        Task { @MainActor [context] in
            context.insert(session)
            do {
                try context.save()
                DebugLogger.shared.log("Session saved successfully")
            } catch {
                DebugLogger.shared.log("Session save FAILED: \(error.localizedDescription)")
            }
        }
    }
    
    private func geocodeLocation(_ location: CLLocation, completion: @escaping (String?) -> Void) {
        let geocoder = CLGeocoder()
        geocoder.reverseGeocodeLocation(location) { placemarks, error in
            if let p = placemarks?.first {
                let name = p.name ?? p.thoroughfare ?? p.locality ?? "Unknown Location"
                completion(name)
            } else {
                completion("Unknown Location")
            }
        }
    }
    
    private func recordDataPoint() {
        guard let session = currentSession, let location = locationManager.latestLocation else { return }
        let reading = SpeedReading(
            timestamp: .now,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            speed: speedEngine.speed,
            speedLimit: speedEngine.limit,
            overLimit: speedEngine.status == .over
        )
        session.readings.append(reading)
    }
}