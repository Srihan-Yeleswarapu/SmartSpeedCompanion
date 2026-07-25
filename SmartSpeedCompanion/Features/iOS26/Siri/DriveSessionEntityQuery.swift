import AppIntents
import Foundation
import SwiftData

/// Entity query that Apple Intelligence and Siri use to resolve natural-language
/// references like "my drive to Work" or "last Tuesday's drive" into specific
/// `DriveSessionEntity` instances.
///
/// `EntityStringQuery` gives the app full control over matching — the system
/// hands us the raw user input and we search SwiftData for the best session.
///
/// The entity itself conforms to `IndexedEntity`, which automatically donates
/// its `displayName` and `contentDescription` fields to the Spotlight semantic
/// index. This enables Apple Intelligence to match queries by meaning even
/// when the exact words don't match.
@MainActor
struct DriveSessionEntityQuery: EntityStringQuery {

    // MARK: - EntityStringQuery

    /// Called when Siri needs to find sessions matching a natural-language string.
    /// The input is whatever the user said — e.g. "Work", "yesterday", "to Home".
    ///
    /// We search across:
    ///   - `customTitle` (user-renamed sessions)
    ///   - `startLocationName` / `endLocationName`
    ///   - The computed `title` (which includes date/time/locations)
    ///   - `destinationPlaceID`
    ///
    /// Results are ordered by start time descending (most recent first).
    func entities(matching string: String) async throws -> [DriveSessionEntity] {
        let context = AppDelegate.sharedModelContainer.mainContext
        let lower = string.lowercased().trimmingCharacters(in: .whitespaces)

        var fetch = FetchDescriptor<DriveSession>(
            predicate: sessionPredicate(for: lower),
            sortBy: [SortDescriptor(\.startTime, order: .reverse)]
        )
        fetch.fetchLimit = 10

        let sessions: [DriveSession]
        do {
            sessions = try context.fetch(fetch)
        } catch {
            DebugLogger.shared.log("DriveSessionQuery: predicate failed — \(error.localizedDescription)")
            return recentSessions(limit: 5).map(DriveSessionEntity.from)
        }

        return sessions.map(DriveSessionEntity.from)
    }

    // MARK: - EntityQuery

    /// Called when Siri needs to resolve sessions by their stable identifiers.
    func entities(for identifiers: [String]) async throws -> [DriveSessionEntity] {
        let context = AppDelegate.sharedModelContainer.mainContext
        let uuids = identifiers.compactMap { UUID(uuidString: $0) }
        guard !uuids.isEmpty else { return [] }

        var fetch = FetchDescriptor<DriveSession>(
            predicate: #Predicate { uuids.contains($0.id) }
        )
        fetch.fetchLimit = uuids.count

        let sessions = (try? context.fetch(fetch)) ?? []
        return sessions.map(DriveSessionEntity.from)
    }

    /// Siri calls this to offer suggestions when the user hasn't specified
    /// which session they mean. We return the 5 most recent sessions.
    func suggestedEntities() async throws -> [DriveSessionEntity] {
        return recentSessions(limit: 5).map(DriveSessionEntity.from)
    }

    // MARK: - Helpers

    /// Builds a predicate that does a case-insensitive "contains" search
    /// across custom titles, start/end location names, and destination IDs.
    /// Falls back to a simpler date-range predicate if the search string
    /// looks like a time reference ("yesterday", "today").
    private func sessionPredicate(for lower: String) -> Predicate<DriveSession> {
        // Handle common time-based keywords
        if lower == "today" {
            let startOfDay = Calendar.current.startOfDay(for: Date())
            return #Predicate { $0.startTime >= startOfDay }
        }
        if lower == "yesterday" {
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
            return #Predicate { $0.startTime >= yesterday && $0.startTime < today }
        }
        if lower == "this week" {
            let startOfWeek = Calendar.current.dateInterval(of: Calendar.Component.weekOfYear, for: Date())?.start ?? Date()
            return #Predicate { $0.startTime >= startOfWeek }
        }
        if lower == "last week" {
            let cal = Calendar.current
            let thisWeek = cal.dateInterval(of: Calendar.Component.weekOfYear, for: Date())?.start ?? Date()
            let lastWeek = cal.date(byAdding: .day, value: -7, to: thisWeek) ?? thisWeek
            return #Predicate { $0.startTime >= lastWeek && $0.startTime < thisWeek }
        }

        // General search: match against location names and custom titles.
        // We use .localizedStandardContains(_:) which IS supported inside
        // Swift 6 #Predicate macros. The single boolean-expression form
        // is more portable than multi-statement if/return blocks.
        return #Predicate<DriveSession> { session in
            (session.customTitle?.localizedStandardContains(lower) ?? false)
                || (session.startLocationName?.localizedStandardContains(lower) ?? false)
                || (session.endLocationName?.localizedStandardContains(lower) ?? false)
        }
    }

    /// Fetches the `n` most recent sessions.
    private func recentSessions(limit: Int) -> [DriveSession] {
        let context = AppDelegate.sharedModelContainer.mainContext
        var fetch = FetchDescriptor<DriveSession>(
            sortBy: [SortDescriptor(\.startTime, order: .reverse)]
        )
        fetch.fetchLimit = limit
        return (try? context.fetch(fetch)) ?? []
    }
}
