import Foundation
import SwiftData

@MainActor
public final class AnalyticsViewModel: ObservableObject {
    @Published public var driveSessions: [DriveSession] = []
    @Published public var selectedSession: DriveSession?
    
    private var modelContext: ModelContext?
    
    public init() {}
    
    public func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }
    
    public func selectSession(_ session: DriveSession) {
        self.selectedSession = session
    }
    
    // MARK: - Computed Properties for UI
    
    public var drivingScore: Int {
        guard let session = selectedSession else { return 0 }
        // Simple scoring based on adherence to limit
        return Int(session.percentWithinLimit * 100)
    }
    
    public var formattedDuration: String {
        guard let session = selectedSession else { return "0m" }
        let minutes = Int(session.durationSeconds / 60)
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes)m"
    }
    
    public var formattedPercentSafe: String {
        guard let session = selectedSession else { return "0%" }
        return String(format: "%.0f%%", session.percentWithinLimit * 100)
    }
    
    public var longestOverstreak: String {
        guard let session = selectedSession else { return "0:00" }
        // Iterate readings to find the longest continuous block of overspeeding
        var maxStreak: TimeInterval = 0
        var currentStart: Date?
        
        for reading in session.readings.sorted(by: { $0.timestamp < $1.timestamp }) {
            if reading.speed > Double(reading.speedLimit) && Double(reading.speedLimit) > 0 {
                if currentStart == nil {
                    currentStart = reading.timestamp
                } else {
                    let streak = reading.timestamp.timeIntervalSince(currentStart!)
                    if streak > maxStreak {
                        maxStreak = streak
                    }
                }
            } else {
                currentStart = nil
            }
        }
        
        let minutes = Int(maxStreak) / 60
        let seconds = Int(maxStreak) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    public var avgSpeedOverLimit: Int {
        guard let session = selectedSession else { return 0 }
        let overReadings = session.readings.filter { $0.speed > $0.speedLimit && $0.speedLimit > 0 }
        guard !overReadings.isEmpty else { return 0 }
        
        let totalOver = overReadings.reduce(0.0) { $0 + ($1.speed - $1.speedLimit) }
        return Int(totalOver / Double(overReadings.count))
    }
    
    // MARK: - Logic
    
    public func deleteSession(_ session: DriveSession) {
        if let idx = driveSessions.firstIndex(of: session), let ctx = modelContext {
            ctx.delete(session)
            driveSessions.remove(at: idx)
            try? ctx.save()
        }
        if selectedSession == session {
            selectedSession = nil
        }
    }
    
    public func totalDistance(for session: DriveSession) -> Double {
        let avgSpeed = session.readings.reduce(0.0) { $0 + $1.speed } / Double(max(1, session.readings.count))
        return avgSpeed * (session.durationSeconds / 3600.0) // miles
    }
}
