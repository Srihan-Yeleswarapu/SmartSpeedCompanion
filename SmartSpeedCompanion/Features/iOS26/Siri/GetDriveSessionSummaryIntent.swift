import AppIntents
import Foundation
import SwiftData

// MARK: - Formatting helpers (shared across intents)

/// Shared formatting utilities used by all drive-summary intents.
enum DriveSummaryFormatter {
    static func formattedDuration(_ totalSec: TimeInterval) -> String {
        let total = Int(totalSec)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60

        if h > 0 {
            return "\(h) hour\(h == 1 ? "" : "s") and \(m) minute\(m == 1 ? "" : "s")"
        } else if m > 0 {
            return "\(m) minute\(m == 1 ? "" : "s") and \(s) second\(s == 1 ? "" : "s")"
        } else {
            return "\(s) second\(s == 1 ? "" : "s")"
        }
    }

    /// Builds a natural-language summary of all session metrics.
    static func formatSummary(_ s: DriveSessionEntity) -> String {
        let durationStr = formattedDuration(s.durationSeconds)
        let pctSafe = Int(s.percentWithinLimit * 100)
        let overstreakStr = formattedDuration(TimeInterval(s.longestOverstreakSeconds))
        let dateStr = formattedDate(s.startTime)
        let timeStr = formattedTime(s.startTime)

        var parts: [String] = []

        // Opening line with session identity and date
        if let route = s.routeDescription {
            parts.append("Your drive \(route) on \(dateStr) at \(timeStr)")
        } else {
            parts.append("Your drive on \(dateStr) at \(timeStr)")
        }

        // Core metrics
        parts.append("lasted \(durationStr)")

        if s.drivingScore >= 90 {
            parts.append("with an excellent driving score of \(s.drivingScore) out of 100")
        } else if s.drivingScore >= 70 {
            parts.append("with a good driving score of \(s.drivingScore) out of 100")
        } else if s.drivingScore >= 50 {
            parts.append("with a fair driving score of \(s.drivingScore) out of 100")
        } else {
            parts.append("with a driving score of \(s.drivingScore) out of 100")
        }

        // Speed compliance
        if pctSafe >= 99 {
            parts.append("You stayed within the speed limit nearly the entire drive")
        } else if pctSafe >= 90 {
            parts.append("You were within the speed limit \(pctSafe) percent of the time")
        } else if pctSafe >= 75 {
            parts.append("You were within the speed limit \(pctSafe) percent of the time")
        } else {
            parts.append("You were within the speed limit \(pctSafe) percent of the time")
        }

        // Overspeed details (only if the user actually went over)
        if s.longestOverstreakSeconds > 0 || s.avgMphOverLimit > 0 {
            let avgStr = String(format: "%.1f", s.avgMphOverLimit)
            parts.append("Your longest continuous speeding period was \(overstreakStr)")

            if s.avgMphOverLimit > 0 {
                parts.append("averaging \(avgStr) miles per hour over the limit when speeding")
            }

            if s.maxOverLimitMph > 1 {
                let maxStr = String(format: "%.0f", s.maxOverLimitMph)
                parts.append("with a maximum of \(maxStr) miles per hour over the limit")
            }
        } else {
            parts.append("Great job staying at or under the speed limit")
        }

        // Top speed
        let maxStr = String(format: "%.0f", s.maxSpeedMph)
        parts.append("Your top speed was \(maxStr) miles per hour")

        return parts.joined(separator: ". ") + "."
    }

    private static func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMMM d"
        f.locale = .current
        return f.string(from: date)
    }

    private static func formattedTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        f.locale = .current
        return f.string(from: date)
    }

    /// Wraps a dynamic string in `IntentDialog` so it can be passed to `.result(dialog:)`.
    /// String literals would auto-convert via `ExpressibleByStringLiteral`, but computed
    /// strings (like function returns) need an explicit wrapper.
    static func dialog(_ text: String) -> IntentDialog {
        IntentDialog(stringLiteral: text)
    }
}

// MARK: - GetDriveSessionSummaryIntent

/// Intent that returns a comprehensive summary of a specific drive session.
///
/// Siri/Apple Intelligence resolves a `DriveSessionEntity` via the entity query
/// (matching natural language like "drove to Work") and passes it here.
/// The intent formats all the metrics into a single, natural-sounding dialog
/// that Siri speaks back to the user.
struct GetDriveSessionSummaryIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Drive Session Summary"
    static var description = IntentDescription(
        "Get a detailed summary of a specific drive session." as LocalizedStringResource,
        categoryName: "Driving" as LocalizedStringResource,
        searchKeywords: ["drive", "session", "summary", "score", "speed"]
    )

    /// When `true`, Siri can answer without bringing Speedio to the foreground.
    static var openAppWhenRun: Bool = false

    /// The session to summarise. Resolved by `DriveSessionEntityQuery` from
    /// whatever the user said — e.g. "when I drove to Work".
    @Parameter(title: "Drive Session",
               description: "Which drive session to look up.")
    var session: DriveSessionEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        return .result(dialog: DriveSummaryFormatter.dialog(
            DriveSummaryFormatter.formatSummary(session)
        ))
    }
}

// MARK: - GetLatestDriveSummaryIntent

/// Intent that answers "how was my last drive" — no parameter needed.
struct GetLatestDriveSummaryIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Latest Drive Summary"
    static var description = IntentDescription(
        "Get a summary of your most recent drive session." as LocalizedStringResource,
        categoryName: "Driving" as LocalizedStringResource,
        searchKeywords: ["last", "latest", "recent", "drive", "summary"]
    )
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = AppDelegate.sharedModelContainer.mainContext
        var fetch = FetchDescriptor<DriveSession>(
            sortBy: [SortDescriptor<DriveSession>(\.startTime, order: .reverse)]
        )
        fetch.fetchLimit = 1

        guard let session = (try? context.fetch(fetch))?.first else {
            return .result(dialog: DriveSummaryFormatter.dialog(
                "You don't have any recorded drives yet. Start a drive session first and I'll be able to tell you how it went."
            ))
        }

        let entity = DriveSessionEntity.from(session)
        return .result(dialog: DriveSummaryFormatter.dialog(
            DriveSummaryFormatter.formatSummary(entity)
        ))
    }
}

// MARK: - GetTodayDriveSummaryIntent

/// Intent that answers "how was my driving today" — aggregates all today's sessions.
struct GetTodayDriveSummaryIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Today's Drive Summary"
    static var description = IntentDescription(
        "Get a summary of all your drives from today." as LocalizedStringResource,
        categoryName: "Driving" as LocalizedStringResource,
        searchKeywords: ["today", "drive", "summary"]
    )
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = AppDelegate.sharedModelContainer.mainContext
        let startOfDay = Calendar.current.startOfDay(for: Date())

        var fetch = FetchDescriptor<DriveSession>(
            predicate: #Predicate<DriveSession> { $0.startTime >= startOfDay },
            sortBy: [SortDescriptor<DriveSession>(\.startTime, order: .reverse)]
        )

        let sessions = (try? context.fetch(fetch)) ?? []
        guard !sessions.isEmpty else {
            return .result(dialog: DriveSummaryFormatter.dialog(
                "You haven't gone for any drives today."
            ))
        }

        let totalSeconds = sessions.reduce(0) { $0 + $1.durationSeconds }
        let scores = sessions.map { $0.drivingScore }
        let avgScore = scores.reduce(0, +) / max(scores.count, 1)
        let bestScore = scores.max() ?? 0
        let totalStr = DriveSummaryFormatter.formattedDuration(totalSeconds)

        let dialog = "You've had \(sessions.count) drive\(sessions.count == 1 ? "" : "s") today totalling \(totalStr). " +
            "Your average score was \(avgScore) with a best of \(bestScore)."

        return .result(dialog: DriveSummaryFormatter.dialog(dialog))
    }
}
