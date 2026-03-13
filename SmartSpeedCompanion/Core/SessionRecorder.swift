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
    
    public init(speedEngine: SpeedEngine, locationManager: LocationManager) {
        self.speedEngine = speedEngine
        self.locationManager = locationManager
    }
    
    public func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }
    
    public func startSession() {
        guard !isRecording else { return }
        
        let newSession = DriveSession(startTime: .now)
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
    }
    
    public func endSession() -> DriveSession? {
        guard isRecording, let session = currentSession else { return nil }
        
        recordingTimer?.invalidate()
        recordingTimer = nil
        isRecording = false
        
        session.endTime = .now
        
        let completedSession = session
        currentSession = nil
        
        if let location = locationManager.latestLocation {
            geocodeLocation(location) { [weak self] (name: String?) in
                completedSession.endLocationName = name
                self?.saveSession(completedSession)
            }
        } else {
            saveSession(completedSession)
        }
        
        return completedSession
    }
    
    private func saveSession(_ session: DriveSession) {
        if let context = modelContext {
            // We want to make sure it's on the main thread for mainactor modelContext
            Task { @MainActor in
                context.insert(session)
                do {
                    try context.save()
                    print("Session saved successfully!")
                } catch {
                    print("Failed to save session: \(error)")
                }
            }
        } else {
            print("SessionRecorder lacks a ModelContext! Cannot save session.")
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
