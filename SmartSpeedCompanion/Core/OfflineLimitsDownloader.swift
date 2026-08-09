// OfflineLimitsDownloader.swift
//
// The former bulk offline downloader queried OpenStreetMap Overpass and wrote
// OSM rows into the same cache used by driving. HERE is now authoritative, so
// this compatibility type intentionally performs no network requests and never
// writes cache data. A future offline-download feature must be implemented with
// HERE data before it is exposed to users.

import Foundation
import CoreLocation

public struct OfflineLimitsEstimate: Equatable, Sendable {
    public let roadCount: Int
    public let sizeBytes: Int64
    public let estimatedSeconds: Int
    public let isReal: Bool

    public init(roadCount: Int, sizeBytes: Int64, estimatedSeconds: Int, isReal: Bool) {
        self.roadCount = roadCount
        self.sizeBytes = sizeBytes
        self.estimatedSeconds = estimatedSeconds
        self.isReal = isReal
    }

    public var sizeLabel: String {
        let bytes = Double(sizeBytes)
        if bytes < 1024 { return "\(Int(bytes)) B" }
        if bytes < 1024 * 1024 { return String(format: "%.0f kB", bytes / 1024) }
        return String(format: "%.1f MB", bytes / (1024 * 1024))
    }

    public var timeLabel: String {
        if estimatedSeconds < 60 { return "~\(max(1, estimatedSeconds)) s" }
        let minutes = estimatedSeconds / 60
        let seconds = estimatedSeconds % 60
        return seconds == 0 ? "~\(minutes) min" : "~\(minutes) min \(seconds) s"
    }
}

public struct OfflineLimitsDownloadResult: Sendable {
    public let roadCount: Int
    public let sizeBytes: Int64
    public let isPinned: Bool
    public let radiusMiles: Double
}

public final class OfflineLimitsDownloader: @unchecked Sendable {
    public static let shared = OfflineLimitsDownloader()

    private init() {}

    /// Compatibility estimate for old callers. It is explicitly heuristic and
    /// does not contact Overpass or any other non-HERE provider.
    public func estimate(
        center: CLLocationCoordinate2D,
        radiusMiles: Double
    ) async -> OfflineLimitsEstimate {
        _ = center
        return heuristicEstimate(radiusMiles: radiusMiles)
    }

    public func heuristicEstimate(radiusMiles: Double) -> OfflineLimitsEstimate {
        let clampedRadius = max(0, radiusMiles)
        let roadCount = Int(Double.pi * clampedRadius * clampedRadius * 90)
        let bytes = Int64(Double(roadCount) * 12 * 110)
        return OfflineLimitsEstimate(
            roadCount: roadCount,
            sizeBytes: bytes,
            estimatedSeconds: max(5, Int(Double(roadCount) / 1200)),
            isReal: false
        )
    }

    /// Disabled compatibility API. It cannot create an OSM-backed zone.
    public func download(
        center: CLLocationCoordinate2D,
        radiusMiles: Double,
        pinned: Bool,
        onProgress: @escaping @Sendable (Double) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async -> OfflineLimitsDownloadResult {
        _ = center
        _ = onProgress
        _ = isCancelled
        DebugLogger.shared.log("OfflineLimitsDownloader: disabled; HERE-backed offline download is required")
        return OfflineLimitsDownloadResult(
            roadCount: 0,
            sizeBytes: 0,
            isPinned: pinned,
            radiusMiles: radiusMiles
        )
    }

    /// Parse an OSM `maxspeed` value for the isolated legacy Overpass provider.
    /// This helper does not make OSM an active source; SpeedLimitService never
    /// instantiates that provider.
    public static func mph(fromMaxspeed raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let isKmh = trimmed.contains("km/h") || trimmed.contains("kmh") || trimmed.contains("kph")
        var digits = ""
        for character in trimmed {
            if character.isNumber || character == "." {
                digits.append(character)
            } else if !digits.isEmpty {
                break
            }
        }
        guard let number = Double(digits), number > 0, number <= 200 else { return nil }
        return isKmh ? Int((number * 0.621371).rounded()) : Int(number.rounded())
    }
}
