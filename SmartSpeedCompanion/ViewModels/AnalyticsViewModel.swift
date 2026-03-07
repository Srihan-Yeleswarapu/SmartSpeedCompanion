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
        guard let session = selectedSession else { return "0h 0m 0s" }
        let duration = Int(session.durationSeconds) // Extract the property safely here
        let h = duration / 3600
        let m = (duration % 3600) / 60
        let s = duration % 60
        return "\(h)h \(m)m \(s)s"
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
}
