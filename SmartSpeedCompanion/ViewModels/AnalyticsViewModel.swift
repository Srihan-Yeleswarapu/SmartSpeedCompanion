import Foundation
import SwiftData
import SwiftUI

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
        let sessionIdToDelete = session.id

        // 1. Clear selection FIRST. CRITICAL: do NOT wrap this in
        // `withAnimation` — the implicit exit animation keeps
        // `AnalyticsContentView` (with its `GeometryReader`) mounted long
        // enough for the SwiftData commit below to trip
        // `_FullFutureBackingData.getValue(forKey:)` (TestFlight FB7,
        // v2.2.0 b361).
        if selectedSession?.id == sessionIdToDelete {
            selectedSession = nil
        }

        // 2. DEFER the SwiftData mutation off the current SwiftUI render
        // pass. Once `selectedSession = nil` has propagated and the
        // GeometryReader inside AnalyticsContentView has unmounted, it is
        // safe to commit the delete. Reading `session.isDeleted` inside
        // the deferred task is itself a BackingData getValue() call and
        // reproduces the same crash during the tombstone tick, so we
        // intentionally do NOT touch it here.
        Task { @MainActor in
            context.delete(session)
            do {
                try context.save()
            } catch {
                print("Failed to save deletion: \(error)")
            }
        }
    }
    
    public func toggleStar(_ session: DriveSession, context: ModelContext) {
        let current = session.isStarred ?? false
        session.isStarred = !current
        try? context.save()
    }
    
    /// Deletes all non-starred sessions older than 30 days. Deferred off
    /// the current render pass for the same reason as `deleteSession`:
    /// a SwiftData tombstone during the same tick that a GeometryReader
    /// ancestor is rendering crashes `_FullFutureBackingData.getValue(forKey:)`
    /// (TestFlight FB7, v2.2.0 b361).
    public func purgeOldSessions(sessions: [DriveSession], context: ModelContext) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let victims = sessions.filter { session in
            guard !session.isDeleted else { return false }
            let isStarred = session.isStarred ?? false
            return !isStarred && session.startTime < cutoff
        }
        guard !victims.isEmpty else { return }

        // Drop any selected session up-front so GeometryReader ancestors unroll.
        if let selected = selectedSession, victims.contains(where: { $0.id == selected.id }) {
            selectedSession = nil
        }

        Task { @MainActor in
            // Do NOT read `session.isDeleted` here — that BackingData
            // getValue(forKey:) read is itself the FB7 crash repro.
            // `context.delete` is idempotent against an already-tombstoned
            // row, so re-running over `victims` is safe.
            for session in victims {
                context.delete(session)
            }
            try? context.save()
        }
    }
}
