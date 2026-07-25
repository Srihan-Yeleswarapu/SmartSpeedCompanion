import AppIntents
import Foundation

/// An `AppEntity` that wraps a `DriveSession` so Apple Intelligence and Siri
/// can understand, search, and reference past drives by name, location, or time.
///
/// Conforms to `IndexedEntity` so session metadata is donated to the on-device
/// Spotlight semantic index. The `id` property is automatically used as the
/// Spotlight `uniqueIdentifier`, and the `displayRepresentation` provides the
/// title/subtitle shown in search results. This enables Apple Intelligence to
/// match queries like *"that drive where I was going really fast"* using
/// Spotlight's semantic understanding.
///
/// > Note: The `@Property(indexingKey:)` macro would allow mapping individual
/// > fields to specific `CSSearchableItemAttributeSet` attributes for finer-grained
/// > control, but it requires iOS 18.4+ and changes the stored property type to
/// > `EntityProperty<T>`, complicating the `from()` factory. The default
/// > `IndexedEntity` behavior (which indexes `id` and `displayRepresentation`)
/// > is sufficient for Spotlight semantic search to work effectively.
///
/// Entity resolution for parameterised intents is handled by
/// `DriveSessionEntityQuery` (`EntityStringQuery`), which searches SwiftData
/// for sessions matching the user's natural-language input.
struct DriveSessionEntity: IndexedEntity {
    // MARK: - AppEntity conformance

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(stringLiteral: "Drive Session")
    }

    @MainActor
    static var defaultQuery = DriveSessionEntityQuery()

    /// The stable identifier — inherited as the Spotlight `uniqueIdentifier`.
    var id: String                       // DriveSession.id.uuidString

    /// The session title (custom or auto-generated date/location title).
    var title: String

    var startTime: Date
    var endTime: Date?
    var durationSeconds: TimeInterval
    var drivingScore: Int
    var percentWithinLimit: Double       // 0.0 – 1.0
    var longestOverstreakSeconds: Int
    var avgMphOverLimit: Double
    var maxSpeedMph: Double
    var maxOverLimitMph: Double
    var startLocationName: String?
    var endLocationName: String?
    var customTitle: String?

    /// Route description (e.g. "Home to Work").
    /// This is the primary field Apple Intelligence uses for semantic understanding.
    var routeDescription: String?

    var displayRepresentation: DisplayRepresentation {
        let subtitle: String
        if let route = routeDescription {
            subtitle = "Score: \(drivingScore) — \(route)"
        } else {
            subtitle = "Score: \(drivingScore)"
        }
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: subtitle
        )
    }

    // MARK: - Factory

    /// Creates a `DriveSessionEntity` from a persisted `DriveSession`.
    /// Pre-computes all the computed properties so the entity is a plain
    /// value type that doesn't depend on SwiftData's faulting model.
    static func from(_ session: DriveSession) -> DriveSessionEntity {
        let hasStart = session.startLocationName.map { $0 != "Unknown Location" } ?? false
        let hasEnd = session.endLocationName.map { $0 != "Unknown Location" } ?? false

        let route: String?
        if hasStart, hasEnd,
           let s = session.startLocationName,
           let e = session.endLocationName {
            route = "\(s) to \(e)"
        } else if hasStart, let s = session.startLocationName {
            route = "From \(s)"
        } else if hasEnd, let e = session.endLocationName {
            route = "To \(e)"
        } else {
            route = nil
        }

        return DriveSessionEntity(
            id: session.id.uuidString,
            title: session.title,
            startTime: session.startTime,
            endTime: session.endTime,
            durationSeconds: session.durationSeconds,
            drivingScore: session.drivingScore,
            percentWithinLimit: session.percentWithinLimit,
            longestOverstreakSeconds: session.longestOverstreak,
            avgMphOverLimit: session.avgMphOverLimit,
            maxSpeedMph: session.maxSpeed,
            maxOverLimitMph: session.maxOverLimit,
            startLocationName: session.startLocationName,
            endLocationName: session.endLocationName,
            customTitle: session.customTitle,
            routeDescription: route
        )
    }
}
