import Foundation
import SwiftData

/// ViewModel for computing statistics and feeding the Analytics views.
@MainActor
public final class AnalyticsViewModel: ObservableObject {
    @Published public var selectedSession: DriveSession?
    
    public init() {}
    
    /// Selects a new session to display in analytics dashboard
    public func selectSession(_ session: DriveSession?) {
        self.selectedSession = session
    }
    
    // Extracted formatted stats for the UI
    public var formattedDuration: String {
        guard let session = selectedSession else { return "--" }
        let duration = Int(session.durationSeconds)
        let h = duration / 3600
        let m = (duration % 3600) / 60
        let s = duration % 60
        
        if h > 0 {
            return "\(h)h \(m)m"
        } else if m > 0 {
            return "\(m)m \(s)s"
        } else {
            return "\(s)s"
        }
    }
    
    public var formattedPercentSafe: String {
        guard let session = selectedSession else { return "100%" }
        return String(format: "%.0f%%", session.percentWithinLimit * 100)
    }
    
    public var longestOverstreak: String {
        guard let session = selectedSession else { return "0s" }
        return "\(session.longestOverstreak)s"
    }
    
    public var avgSpeedOverLimit: String {
        guard let session = selectedSession else { return "0 mph" }
        return String(format: "%.1f mph", session.avgMphOverLimit)
    }
    
    public var drivingScore: Int {
        guard let session = selectedSession else { return 100 }
        return session.drivingScore
    }
    
    public func deleteSession(_ session: DriveSession, context: ModelContext) {
        context.delete(session)
        // No need to explicitly save as SwiftData handles it, but good for immediate persistence
        try? context.save()
        if selectedSession?.id == session.id {
            selectedSession = nil
        }
    }
}
