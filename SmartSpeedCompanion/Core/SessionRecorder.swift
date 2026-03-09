import Foundation
import SwiftData

/// Records the drive session by capturing GPS data points every second.
@MainActor
public final class SessionRecorder: ObservableObject {
    @Published public var isRecording = false
    public var currentSession: DriveSession?
    
    private var modelContext: ModelContext?
    private let locationManager: LocationManager
    private var recordingTimer: Timer?
    
    public init(locationManager: LocationManager) {
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
        
        // Save to SwiftData
        if let context = modelContext {
            context.insert(session)
            do {
                try context.save()
            } catch {
                print("Failed to save session: \(error)")
            }
        }
        
        let completedSession = currentSession
        currentSession = nil
        return completedSession
    }
    
    private func recordDataPoint() {
        guard let session = currentSession, let location = locationManager.latestLocation else { return }
        let speed = max(0, location.speed * 2.23694)
        let limit = SpeedLimitBrain.shared.currentLimit
        let limitSource = SpeedLimitBrain.shared.limitSource.rawValue
        
        let threshold = Double(limit + 5) // MVP 5mph buffer
        let isOver = speed > threshold
        
        let reading = SpeedReading(
            timestamp: .now,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            speed: speed,
            speedLimit: limit,
            overLimit: isOver,
            limitSource: limitSource
        )
        session.readings.append(reading)
    }
}
