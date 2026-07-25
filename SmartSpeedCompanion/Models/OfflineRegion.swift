import Foundation

/// A saved offline map region stored in UserDefaults as JSON.
/// Used by the Offline Map Region Download feature to track which
/// areas the user has cached for offline browsing.
public struct OfflineRegion: Codable, Identifiable, Equatable {
    public var id: String // "lat,lon" composite key
    public let label: String
    public let lat: Double
    public let lon: Double
    public let timestamp: Date

    public init(label: String, lat: Double, lon: Double, timestamp: Date = Date()) {
        self.id = "\(lat),\(lon)"
        self.label = label
        self.lat = lat
        self.lon = lon
        self.timestamp = timestamp
    }
}
