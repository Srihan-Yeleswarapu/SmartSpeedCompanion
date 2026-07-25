import AppIntents
import CoreSpotlight
import Foundation

/// An `AppEntity` that wraps a `DriveSession` so Apple Intelligence and Siri
/// can understand, search, and reference past drives by name, location, or time.
///
/// Conforms to `IndexedEntity` so session metadata is donated to the on-device
/// Spotlight semantic index. This enables Apple Intelligence to match queries
/// like *"that drive where I was going really fast"* or *"how was my trip to
/// the airport last week"* using meaning, not just string matching.
///
/// The `@Property(indexingKey:)` annotations map key fields to specific
/// `CSSearchableItemAttributeSet` attributes — the system indexes these fields
/// and makes them discoverable by Spotlight. The `displayName` is the primary
/// identifier shown in search results, while `contentDescription` is the main
/// field Apple Intelligence uses for semantic understanding.
///
/// Entity resolution for parameterised intents is handled by
/// `DriveSessionEntityQuery` (`EntityStringQuery`), which searches SwiftData
/// for sessions matching the user's natural-language input.
struct DriveSessionEntity: IndexedEntity {
    // MARK: - AppEntity conformance

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Drive Session"
    static var defaultQuery = DriveSessionEntityQuery()

    /// The stable identifier — inherited as the Spotlight `uniqueIdentifier`.
    var id: String                       // DriveSession.id.uuidString

    /// The session title (custom or auto-generated date/location title).
    /// Indexed as the primary display name in Spotlight search results.
    @Property(indexingKey: \.displayName)
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
    /// Indexed as the content description — this is the primary field Apple
    /// Intelligence uses for semantic understanding and matching.
    @Property(indexingKey: \.contentDescription)
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
