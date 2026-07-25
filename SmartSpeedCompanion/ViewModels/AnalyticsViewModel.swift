import Foundation
import CoreLocation
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
    
    /// Returns an enriched session title that uses named location names instead of
    /// addresses when the session's start or end coordinate matches a saved named location.
    /// Falls back to `session.title` when no named locations match.
    public func sessionTitleWithNamedLocations(_ session: DriveSession, namedLocations: [NamedLocation]) -> String {
        guard !namedLocations.isEmpty else { return session.title }
        
        // Check the first and last reading's coordinates against named locations
        let startCoord: CLLocationCoordinate2D?
        let endCoord: CLLocationCoordinate2D?
        
        if let first = session.readings.first {
            startCoord = CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude)
        } else {
            startCoord = nil
        }
        
        if let last = session.readings.last {
            endCoord = CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude)
        } else {
            endCoord = nil
        }
        
        let startName = startCoord.flatMap { coord -> String? in
            let cl = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            for loc in namedLocations {
                let saved = CLLocation(latitude: loc.latitude, longitude: loc.longitude)
                if cl.distance(from: saved) < 20 { return loc.name }
            }
            return nil
        }
        
        let endName = endCoord.flatMap { coord -> String? in
            let cl = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            for loc in namedLocations {
                let saved = CLLocation(latitude: loc.latitude, longitude: loc.longitude)
                if cl.distance(from: saved) < 20 { return loc.name }
            }
            return nil
        }
        
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "MMM d"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        
        let dayStr = dayFormatter.string(from: session.startTime)
        let timeStr = timeFormatter.string(from: session.startTime)
        let suffix = "at \(timeStr) on \(dayStr)"
        
        if let start = startName, let end = endName {
            return "\(start) to \(end) \(suffix)"
        } else if let start = startName {
            let end = session.endLocationName ?? "Unknown Location"
            if end != "Unknown Location" {
                return "\(start) to \(end) \(suffix)"
            }
            return "\(start) \(suffix)"
        } else if let end = endName {
            let start = session.startLocationName ?? "Unknown Location"
            if start != "Unknown Location" {
                return "\(start) to \(end) \(suffix)"
            }
            return "\(end) \(suffix)"
        }
        
        return session.title
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
