import Foundation

/// A saved offline speed-limit download zone.
///
/// Tracks the center coordinate, radius (miles), and the measured download
/// size so the Offline limits list can show what was downloaded, let the user
/// pin a zone (pinned rows are exempt from the 30-day TTL cleanup), and delete
/// it (deletes the cached road rows inside the zone).
///
/// Persisted as JSON in UserDefaults under `savedLimitsZones` via
/// `DriveViewModel.loadLimitsZones()` / `persistLimitsZones()`.
public struct DownloadedLimitsZone: Codable, Identifiable, Equatable {
    public var id: String { "\(lat),\(lon),\(radiusMiles)" }

    public let label: String
    public let lat: Double
    public let lon: Double
    /// Radius in miles (10...50, matching the slider bounds).
    public let radiusMiles: Double
    /// Number of road rows written to the batch cache.
    public let roadCount: Int
    /// Estimated storage footprint in bytes (rows × ~110 B/row).
    public let sizeBytes: Int64
    /// When true, the zone's cached rows never expire (skipped by the 30-day
    /// TTL cleanup in HERELocalBatchCache). Toggled by the list UI.
    public var isPinned: Bool
    public let downloadedAt: Date

    public init(
        label: String,
        lat: Double,
        lon: Double,
        radiusMiles: Double,
        roadCount: Int,
        sizeBytes: Int64,
        isPinned: Bool,
        downloadedAt: Date = Date()
    ) {
        self.label = label
        self.lat = lat
        self.lon = lon
        self.radiusMiles = radiusMiles
        self.roadCount = roadCount
        self.sizeBytes = sizeBytes
        self.isPinned = isPinned
        self.downloadedAt = downloadedAt
    }
}
