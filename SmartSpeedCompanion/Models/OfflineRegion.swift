import Foundation
import MapKit

/// A saved offline map region stored in UserDefaults as JSON.
/// Used by the Offline Map Region Download feature to track which
/// areas the user has cached for offline browsing.
///
/// New bounding‑box fields (`northLat`, `southLat`, `eastLon`, `westLon`,
/// `latSpan`, `lonSpan`, `estimatedSizeMB`) are optional so JSON stored
/// by older builds decodes cleanly — existing saved regions continue to
/// work and show up in the saved list with just their center point.
public struct OfflineRegion: Codable, Identifiable, Equatable {
    public var id: String // "lat,lon" composite key
    public let label: String
    public let lat: Double
    public let lon: Double
    public let timestamp: Date

    // ── Bounding‑box fields (added for the interactive map picker) ──
    public let northLat: Double?
    public let southLat: Double?
    public let eastLon: Double?
    public let westLon: Double?
    public let latSpan: Double?
    public let lonSpan: Double?
    /// Estimated download size in megabytes (computed from visible area).
    public let estimatedSizeMB: Double?

    /// Creates a region with only a centre point (legacy path).
    public init(label: String, lat: Double, lon: Double, timestamp: Date = Date()) {
        self.id = "\(lat),\(lon)"
        self.label = label
        self.lat = lat
        self.lon = lon
        self.timestamp = timestamp
        self.northLat = nil
        self.southLat = nil
        self.eastLon = nil
        self.westLon = nil
        self.latSpan = nil
        self.lonSpan = nil
        self.estimatedSizeMB = nil
    }

    /// Creates a fully‑specified region with a bounding box from the map picker.
    public init(label: String, region: MKCoordinateRegion, estimatedSizeMB: Double, timestamp: Date = Date()) {
        let north = region.center.latitude + region.span.latitudeDelta / 2.0
        let south = region.center.latitude - region.span.latitudeDelta / 2.0
        let east  = region.center.longitude + region.span.longitudeDelta / 2.0
        let west  = region.center.longitude - region.span.longitudeDelta / 2.0

        self.id = "\(region.center.latitude),\(region.center.longitude)"
        self.label = label
        self.lat = region.center.latitude
        self.lon = region.center.longitude
        self.timestamp = timestamp
        self.northLat = north
        self.southLat = south
        self.eastLon = east
        self.westLon = west
        self.latSpan = region.span.latitudeDelta
        self.lonSpan = region.span.longitudeDelta
        self.estimatedSizeMB = estimatedSizeMB
    }
}
