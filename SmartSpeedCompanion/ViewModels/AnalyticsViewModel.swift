import Foundation
import SwiftData

/// ViewModel for computing statistics and feeding the Analytics views.
@MainActor
public final class AnalyticsViewModel: ObservableObject {
    @Published public var selectedSession: DriveSession?
    @Published public var showSessionPicker: Bool = false
    
    public init() {}
    
    /// Selects a new session to display in analytics dashboard
    public func selectSession(_ session: DriveSession?) {
        self.selectedSession = session
        self.showSessionPicker = false
    }
    
    // MARK: - Formatted Stats
    
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
    
    // MARK: - Actions
    
    public func deleteSession(_ session: DriveSession, context: ModelContext) {
        context.delete(session)
        try? context.save()
        if selectedSession?.id == session.id {
            selectedSession = nil
        }
    }
    
    public func toggleStar(_ session: DriveSession, context: ModelContext) {
        let current = session.isStarred ?? false
        session.isStarred = !current
        try? context.save()
    }
    
    /// Deletes all non-starred sessions older than 30 days.
    public func purgeOldSessions(sessions: [DriveSession], context: ModelContext) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        for session in sessions {
            let isStarred = session.isStarred ?? false
            if !isStarred && session.startTime < cutoff {
                if selectedSession?.id == session.id { selectedSession = nil }
                context.delete(session)
            }
        }
        try? context.save()
    }
}
