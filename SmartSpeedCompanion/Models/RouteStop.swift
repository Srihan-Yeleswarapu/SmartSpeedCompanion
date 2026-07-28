import Foundation
import MapKit

// MARK: - RouteStop
//
// Represents a single intermediate waypoint on a multi-stop route.
// Stores location info and per-leg travel data so the UI can show
// ETAs, distances, and allow reordering without re-fetching routes.
//
// The struct does NOT hold a direct MKMapItem reference to stay
// Codable and value-type simple. `mapItem` is a computed property
// so callers can pass it to MKDirections.Request as a waypoint.

public struct RouteStop: Identifiable, Equatable, Codable, Hashable {

    public let id: UUID
    public let name: String
    public let address: String?
    public let latitude: CLLocationDegrees
    public let longitude: CLLocationDegrees

    // Per-leg estimates — populated after the route is calculated.
    // `travelTimeFromPrevious` is the expected travel time (seconds)
    // from the previous stop/origin to this stop.
    public var travelTimeFromPrevious: TimeInterval?
    /// Distance in meters from the previous stop/origin.
    public var distanceFromPrevious: CLLocationDistance?
    /// The cumulative travel time from the origin to this stop (seconds).
    public var cumulativeTravelTime: TimeInterval?

    public init(
        id: UUID = UUID(),
        name: String,
        address: String? = nil,
        latitude: CLLocationDegrees,
        longitude: CLLocationDegrees,
        travelTimeFromPrevious: TimeInterval? = nil,
        distanceFromPrevious: CLLocationDistance? = nil,
        cumulativeTravelTime: TimeInterval? = nil
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.travelTimeFromPrevious = travelTimeFromPrevious
        self.distanceFromPrevious = distanceFromPrevious
        self.cumulativeTravelTime = cumulativeTravelTime
    }

    // MARK: - Computed Properties

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    public var mapItem: MKMapItem {
        let placemark = MKPlacemark(coordinate: coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = name
        return item
    }

    // MARK: - Equatable

    public static func == (lhs: RouteStop, rhs: RouteStop) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - RouteLeg
//
// Represents one segment of a multi-stop journey (origin → stop1,
// stop1 → stop2, ..., stopN → final destination). The UI renders
// each leg's ETA + distance in the stops sheet.

public struct RouteLeg: Identifiable {
    public let id = UUID()
    public let sourceName: String
    public let destinationName: String
    public let travelTime: TimeInterval
    public let distance: CLLocationDistance
    public let route: MKRoute?

    public var formattedDuration: String {
        let totalMinutes = Int(travelTime / 60)
        if totalMinutes < 60 {
            return "\(totalMinutes) min"
        }
        let hours = totalMinutes / 60
        let mins = totalMinutes % 60
        return "\(hours)h \(mins)m"
    }

    public var formattedDistance: String {
        let miles = distance * 0.000621371
        if miles < 0.1 {
            let feet = distance * 3.28084
            return "\(Int(feet)) ft"
        }
        return String(format: "%.1f mi", miles)
    }
}

// MARK: - OrderingComparison
//
// Result of comparing the user's current stop order against the
// most efficient order found by checking permutations.

public struct OrderingComparison: Identifiable {
    public let id = UUID()
    /// The user's current order of stop IDs.
    public let currentOrder: [UUID]
    /// Total travel time for the current order (seconds).
    public let currentTotalTime: TimeInterval
    /// The most efficient order found.
    public let bestOrder: [UUID]
    /// Total travel time for the best order (seconds).
    public let bestTotalTime: TimeInterval
    /// Time saved by switching to the best order (seconds).
    public var timeSaved: TimeInterval {
        currentTotalTime - bestTotalTime
    }

    public var currentFormatted: String {
        formatTime(currentTotalTime)
    }

    public var bestFormatted: String {
        formatTime(bestTotalTime)
    }

    public var savedFormatted: String {
        guard timeSaved > 30 else { return "Similar" }
        let secs = Int(timeSaved)
        if secs < 60 { return "\(secs)s saved" }
        let mins = secs / 60
        return "\(mins) min saved"
    }

    public var canSaveTime: Bool {
        // 30-second threshold — even small savings matter for drivers
        timeSaved > 30
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds / 60)
        if totalMinutes < 60 {
            return "\(totalMinutes) min"
        }
        let hours = totalMinutes / 60
        let mins = totalMinutes % 60
        return "\(hours)h \(mins)m"
    }
}
