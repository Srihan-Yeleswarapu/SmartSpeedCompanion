import AppIntents
import Foundation
import SwiftData

/// Entity query that Apple Intelligence and Siri use to resolve natural-language
/// references like "my drive to Work" or "last Tuesday's drive" into specific
/// `DriveSessionEntity` instances.
struct DriveSessionEntityQuery: EntityStringQuery {

    // MARK: - EntityStringQuery

    /// Called when Siri needs to find sessions matching a natural-language string.
    /// SwiftData access stays on MainActor while the query itself remains
    /// nonisolated to satisfy AppIntents' Swift 6 protocol boundary.
    func entities(matching string: String) async throws -> [DriveSessionEntity] {
        let lower = string.lowercased().trimmingCharacters(in: .whitespaces)
        return await fetchMatchingEntities(lowercasedQuery: lower)
    }

    // MARK: - EntityQuery

    /// Called when Siri needs to resolve sessions by their stable identifiers.
    func entities(for identifiers: [String]) async throws -> [DriveSessionEntity] {
        let uuids = identifiers.compactMap { UUID(uuidString: $0) }
        guard !uuids.isEmpty else { return [] }

        return await MainActor.run {
            let context = AppDelegate.sharedModelContainer.mainContext
            var fetch = FetchDescriptor<DriveSession>(
                predicate: #Predicate { uuids.contains($0.id) }
            )
            fetch.fetchLimit = uuids.count
            let sessions = (try? context.fetch(fetch)) ?? []
            return sessions.map(DriveSessionEntity.from)
        }
    }

    /// Siri calls this to offer suggestions when the user hasn't specified
    /// which session they mean. We return the five most recent sessions.
    func suggestedEntities() async throws -> [DriveSessionEntity] {
        return await fetchMatchingEntities(lowercasedQuery: nil, limit: 5)
    }

    // MARK: - Main-actor SwiftData helpers

    private func fetchMatchingEntities(
        lowercasedQuery: String?,
        limit: Int = 10
    ) async -> [DriveSessionEntity] {
        await MainActor.run {
            let context = AppDelegate.sharedModelContainer.mainContext
            do {
                var fetch: FetchDescriptor<DriveSession>
                if let lowercasedQuery {
                    fetch = FetchDescriptor<DriveSession>(
                        predicate: Self.sessionPredicate(for: lowercasedQuery),
                        sortBy: [SortDescriptor(\.startTime, order: .reverse)]
                    )
                } else {
                    fetch = FetchDescriptor<DriveSession>(
                        sortBy: [SortDescriptor(\.startTime, order: .reverse)]
                    )
                }
                fetch.fetchLimit = limit
                return try context.fetch(fetch).map(DriveSessionEntity.from)
            } catch {
                DebugLogger.shared.log("DriveSessionQuery: predicate failed — \(error.localizedDescription)")

                // Preserve the original resilient behavior: if a complex
                // search predicate is rejected by SwiftData, still offer the
                // five newest drives rather than returning no Siri results.
                guard lowercasedQuery != nil else { return [] }
                var fallback = FetchDescriptor<DriveSession>(
                    sortBy: [SortDescriptor(\.startTime, order: .reverse)]
                )
                fallback.fetchLimit = 5
                return (try? context.fetch(fallback).map(DriveSessionEntity.from)) ?? []
            }
        }
    }

    /// Builds a case-insensitive search predicate for SwiftData.
    private static func sessionPredicate(for lower: String) -> Predicate<DriveSession> {
        if lower == "today" {
            let startOfDay = Calendar.current.startOfDay(for: Date())
            return #Predicate { $0.startTime >= startOfDay }
        }
        if lower == "yesterday" {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
            return #Predicate { $0.startTime >= yesterday && $0.startTime < today }
        }
        if lower == "this week" {
            let startOfWeek = Calendar.current
                .dateInterval(of: Calendar.Component.weekOfYear, for: Date())?.start ?? Date()
            return #Predicate { $0.startTime >= startOfWeek }
        }
        if lower == "last week" {
            let calendar = Calendar.current
            let thisWeek = calendar
                .dateInterval(of: Calendar.Component.weekOfYear, for: Date())?.start ?? Date()
            let lastWeek = calendar.date(byAdding: .day, value: -7, to: thisWeek) ?? thisWeek
            return #Predicate { $0.startTime >= lastWeek && $0.startTime < thisWeek }
        }

        return #Predicate<DriveSession> { session in
            (session.customTitle?.localizedStandardContains(lower) ?? false)
                || (session.startLocationName?.localizedStandardContains(lower) ?? false)
                || (session.endLocationName?.localizedStandardContains(lower) ?? false)
        }
    }
}
