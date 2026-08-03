// OfflineLimitsDownloader.swift
// Bulk "Download Limits" engine for the Offline feature.
//
// Downloads EVERY speed limit within a radius around the user's current
// location by querying the OpenStreetMap Overpass API (the only provider that
// can return all `maxspeed`-tagged ways in an area in one query). Results are
// written into the same SQLite `HERELocalBatchCache` used by the live
// pipeline, so the normal `SpeedLimitService` lookup path serves them with
// zero extra plumbing — online or off.
//
// WHY CHUNKED:
//   Overpass servers enforce ~180s query timeouts and `maxsize` response
//   limits. A single `way(around:80km)[highway][maxspeed]` query in a metro
//   area can exceed both. We therefore tile the circle with a grid of
//   bounding-box queries (≤ ~64 cells), each returning the ways in that cell
//   with full geometry. Cells are small enough to stay under the server
//   limits yet few enough to keep the whole download to a couple of minutes
//   at max radius (50 mi).
//
// THROTTLING:
//   Overpass publishes a ~2 req/sec/IP limit. We sleep ~0.6s between cells
//   and, on HTTP 429, pause for 60s before continuing (any already-downloaded
//   cells are kept).
//
// ESTIMATE:
//   `estimate(...)` first runs a cheap `out count;` query (count of
//   maxspeed ways in the radius — the "Real" estimate the user chose). If
//   that fails, it falls back to a density heuristic. Size = wayCount ×
//   avgPointsPerWay × ~110 B/row (matches the SQLite row-size comment in
//   HERELocalBatchCache). Time = cellCount × overhead + wayCount / throughput.

import Foundation
import CoreLocation

/// Live-updating estimate shown while the user drags the radius slider.
public struct OfflineLimitsEstimate: Equatable, Sendable {
    public let roadCount: Int
    public let sizeBytes: Int64
    public let estimatedSeconds: Int
    /// True when the estimate came from a real Overpass count query; false
    /// when it is a density heuristic (slider in flight or count failed).
    public let isReal: Bool

    public init(roadCount: Int, sizeBytes: Int64, estimatedSeconds: Int, isReal: Bool) {
        self.roadCount = roadCount
        self.sizeBytes = sizeBytes
        self.estimatedSeconds = estimatedSeconds
        self.isReal = isReal
    }

    /// Human-readable size: "412 kB", "2.4 MB", "87 MB".
    public var sizeLabel: String {
        let b = Double(sizeBytes)
        if b < 1024 { return "\(Int(b)) B" }
        if b < 1024 * 1024 { return String(format: "%.0f kB", b / 1024) }
        return String(format: "%.1f MB", b / (1024 * 1024))
    }

    /// Human-readable time: "~45 s", "~3 min".
    public var timeLabel: String {
        if estimatedSeconds < 60 { return "~\(max(1, estimatedSeconds)) s" }
        let m = estimatedSeconds / 60
        let s = estimatedSeconds % 60
        return s == 0 ? "~\(m) min" : "~\(m) min \(s) s"
    }
}

/// Result of a completed bulk download.
public struct OfflineLimitsDownloadResult: Sendable {
    public let roadCount: Int
    public let sizeBytes: Int64
    public let isPinned: Bool
    public let radiusMiles: Double
}

public final class OfflineLimitsDownloader: @unchecked Sendable {
    public static let shared = OfflineLimitsDownloader()

    // MARK: - Estimate calibration

    /// Average geometry points per maxspeed way (used only for the heuristic
    /// fallback — the real estimate counts actual ways then multiplies).
    private let avgPointsPerWay: Double = 12
    /// Approximate bytes per cached row (see HERELocalBatchCache row comment).
    private let bytesPerRow: Double = 110
    /// Dense-metro ways per square mile (heuristic fallback density).
    private let heuristicWaysPerSqMi: Double = 90
    /// Estimated end-to-end throughput (ways/sec) for the time estimate.
    private let waysPerSecond: Double = 1200
    /// Per-cell network + parse overhead for the time estimate.
    private let secondsPerCell: Double = 0.8
    /// Max grid cells per axis (keeps total requests ≤ 64 for 50 mi radius).
    private let maxCellsPerAxis: Int = 8
    /// Inter-request throttle to stay under Overpass's ~2 req/sec/IP limit.
    private let interRequestDelay: TimeInterval = 0.6
    /// Backoff after HTTP 429.
    private let throttleBackoff: TimeInterval = 60

    private init() {}

    // MARK: - Public API

    /// Compute the road-count / size / time estimate for a radius.
    /// Runs a real Overpass `out count;` query first; falls back to the
    /// density heuristic when the count query fails (offline, server down).
    public func estimate(
        center: CLLocationCoordinate2D,
        radiusMiles: Double
    ) async -> OfflineLimitsEstimate {
        let radiusMeters = radiusMiles * 1609.344
        if let real = await countWays(center: center, radiusMeters: radiusMeters) {
            let bytes = Int64(Double(real) * avgPointsPerWay * bytesPerRow)
            let cells = gridCellCount(radiusMeters: radiusMeters)
            let seconds = Int((Double(cells) * secondsPerCell) + (Double(real) / waysPerSecond))
            return OfflineLimitsEstimate(
                roadCount: real, sizeBytes: bytes,
                estimatedSeconds: max(5, seconds), isReal: true
            )
        }
        return heuristicEstimate(radiusMiles: radiusMiles)
    }

    /// Density-based fallback used while the slider is mid-drag or when the
    /// real count query cannot run. Instant — no network.
    public func heuristicEstimate(radiusMiles: Double) -> OfflineLimitsEstimate {
        let radiusMeters = radiusMiles * 1609.344
        let areaSqMi = Double.pi * radiusMiles * radiusMiles
        let ways = Int(areaSqMi * heuristicWaysPerSqMi)
        let bytes = Int64(Double(ways) * avgPointsPerWay * bytesPerRow)
        let cells = gridCellCount(radiusMeters: radiusMeters)
        let seconds = Int((Double(cells) * secondsPerCell) + (Double(ways) / waysPerSecond))
        return OfflineLimitsEstimate(
            roadCount: ways, sizeBytes: bytes,
            estimatedSeconds: max(5, seconds), isReal: false
        )
    }

    /// Download every speed limit inside the radius and persist it into the
    /// SQLite batch cache. Reports progress (0...1) via `onProgress` and
    /// checks `isCancelled` between cells so the user can abort mid-download
    /// (already-written cells are kept).
    ///
    /// - Parameters:
    ///   - center: download center (user's current GPS coordinate).
    ///   - radiusMiles: 10...50.
    ///   - pinned: when true, stored rows are exempt from the 30-day TTL.
    ///   - onProgress: called on the main-ish progress thread with fraction.
    ///   - isCancelled: returning true aborts after the current cell.
    /// - Returns: row count + bytes written.
    public func download(
        center: CLLocationCoordinate2D,
        radiusMiles: Double,
        pinned: Bool,
        onProgress: @escaping @Sendable (Double) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async -> OfflineLimitsDownloadResult {
        let radiusMeters = radiusMiles * 1609.344
        let cells = gridCells(center: center, radiusMeters: radiusMeters)
        let totalCells = max(1, cells.count)
        var allRoads: [CachedRoad] = []
        var completed = 0

        for (index, cell) in cells.enumerated() {
            if isCancelled() {
                DebugLogger.shared.log("OfflineLimitsDownloader: cancelled at cell \(index)/\(totalCells)")
                break
            }
            // Throttle between requests (skip the very first so we don't
            // sleep before cell 0).
            if index > 0 {
                try? await Task.sleep(nanoseconds: UInt64(interRequestDelay * 1_000_000_000))
            }

            if let roads = await queryCell(cell, pinned: pinned) {
                allRoads.append(contentsOf: roads)
            } else {
                // A failed cell (timeout / 429 / parse) is skipped so the rest
                // of the download survives, but surface it so a partial zone's
                // incompleteness is diagnosable from the debug log.
                DebugLogger.shared.log("OfflineLimitsDownloader: cell \(index)/\(totalCells) failed, skipped")
            }
            completed += 1
            onProgress(Double(completed) / Double(totalCells))

            // Flush periodically so memory stays bounded on the 50 mi path.
            if allRoads.count >= 2000 {
                HERELocalBatchCache.shared.store(roads: allRoads, pinned: pinned)
                allRoads.removeAll(keepingCapacity: true)
            }
        }

        if !allRoads.isEmpty {
            HERELocalBatchCache.shared.store(roads: allRoads, pinned: pinned)
        }
        let rows = countRoads(center: center, radiusMeters: radiusMeters)
        let bytes = Int64(Double(rows) * bytesPerRow)
        DebugLogger.shared.log("OfflineLimitsDownloader: finished \(rows) rows in \(radiusMiles) mi zone")
        return OfflineLimitsDownloadResult(
            roadCount: rows, sizeBytes: bytes,
            isPinned: pinned, radiusMiles: radiusMiles
        )
    }

    // MARK: - Overpass queries

    /// Cheap `out count;` query: number of `[highway][maxspeed]` ways inside
    /// the radius. Returns nil on any failure (network, 429, timeout, parse).
    private func countWays(center: CLLocationCoordinate2D, radiusMeters: Double) async -> Int? {
        let radiusM = Int(radiusMeters.rounded())
        let query = """
        [out:json][timeout:25];
        way(around:\(radiusM),\(center.latitude),\(center.longitude))[highway][maxspeed];
        out count;
        """
        guard let payload = await post(query) else { return nil }
        guard let elements = payload["elements"] as? [[String: Any]] else { return nil }
        for element in elements {
            if let count = element["count"] as? Int {
                return count
            }
            // Some mirrors return a bare element with a "count" key under
            // different casing; be defensive.
            if let count = element["Count"] as? Int { return count }
        }
        return nil
    }

    /// Query one grid cell (`way(bbox)[highway][maxspeed]; out geom tags 1;`)
    /// and convert its ways into CachedRoad rows (one row per decimated
    /// geometry point, named after the way's `name` tag). Returns nil on
    /// failure so the caller can skip the cell and keep going.
    private func queryCell(_ cell: GridCell, pinned: Bool) async -> [CachedRoad]? {
        let query = """
        [out:json][timeout:30];
        way(\(cell.minLat),\(cell.minLon),\(cell.maxLat),\(cell.maxLon))[highway][maxspeed];
        out geom tags 1;
        """
        guard let payload = await post(query) else { return nil }
        guard let elements = payload["elements"] as? [[String: Any]] else { return nil }

        var roads: [CachedRoad] = []
        for element in elements {
            guard let tags = element["tags"] as? [String: Any],
                  let raw = tags["maxspeed"] as? String,
                  let mph = OfflineLimitsDownloader.mph(fromMaxspeed: raw) else { continue }

            let name = (tags["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let osmID = element["id"] as? Int64 ?? 0
            let roadName = name.isEmpty ? "OSM way \(osmID)" : name

            guard let geometry = element["geometry"] as? [[String: Any]] else { continue }
            // Decimate to ~60m spacing so long interstates don't explode into
            // hundreds of near-duplicate rows; the batch-cache spatial lookup
            // uses a 50m radius, so 60m spacing keeps worst-case distance
            // ≈ 30m — still inside the lookup window.
            var lastLat: Double? = nil
            var lastLon: Double? = nil
            for point in geometry {
                guard let lat = point["lat"] as? Double,
                      let lon = point["lon"] as? Double else { continue }
                if let llat = lastLat, let llon = lastLon {
                    let dLat = (lat - llat) * 111_111.0
                    let dLon = (lon - llon) * 111_111.0 * cos(lat * .pi / 180)
                    if (dLat * dLat + dLon * dLon).squareRoot() < 60 { continue }
                }
                roads.append(CachedRoad(
                    roadName: roadName,
                    direction: "",
                    speedLimitMph: mph,
                    latitude: lat,
                    longitude: lon,
                    source: "osm",
                    pinned: pinned
                ))
                lastLat = lat
                lastLon = lon
            }
        }
        return roads
    }

    /// POST an Overpass query and parse the JSON response. Returns nil on
    /// network error, non-2xx, 429 (throttle), or parse failure.
    private func post(_ query: String) async -> [String: Any]? {
        guard let url = URL(string: "https://overpass-api.de/api/interpreter") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 35)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8",
                         forHTTPHeaderField: "Content-Type")
        let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        request.httpBody = Data("data=\(escaped)".utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return nil
        }
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 429 {
            // Honor Overpass throttle: wait out the backoff window, then let
            // the caller continue. Keeps already-downloaded cells intact.
            // The sleep is cancellation-aware so a user abort during the
            // backoff returns promptly instead of hanging ~60 s.
            do {
                try await Task.sleep(nanoseconds: UInt64(throttleBackoff * 1_000_000_000))
            } catch {
                return nil  // cancelled
            }
            return nil
        }
        guard (200..<300).contains(http.statusCode) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Grid math

    private struct GridCell {
        let minLat: Double, minLon: Double, maxLat: Double, maxLon: Double
    }

    /// Number of cells per axis for a given radius (capped at 8 → ≤64 cells).
    private func gridCellCount(radiusMeters: Double) -> Int {
        let cells = max(1, Int(ceil((radiusMeters * 2) / 20_000)))
        return min(maxCellsPerAxis, cells)
    }

    /// Tile the circle's bounding box with a grid; return only the cells that
    /// intersect the circle (corner cells are skipped to save requests).
    private func gridCells(center: CLLocationCoordinate2D, radiusMeters: Double) -> [GridCell] {
        let perAxis = gridCellCount(radiusMeters: radiusMeters)
        let span = radiusMeters * 2
        let latStep = span / 111_111.0 / Double(perAxis)
        let lonStep = span / (111_111.0 * cos(center.latitude * .pi / 180)) / Double(perAxis)

        var cells: [GridCell] = []
        for i in 0..<perAxis {
            for j in 0..<perAxis {
                let minLat = center.latitude - span / (2 * 111_111.0) + Double(i) * latStep
                let maxLat = minLat + latStep
                let minLon = center.longitude - span / (2 * 111_111.0 * cos(center.latitude * .pi / 180)) + Double(j) * lonStep
                let maxLon = minLon + lonStep

                // Cell center distance from the download center (rough);
                // skip cells whose center is beyond radius + half-diagonal.
                let cLat = (minLat + maxLat) / 2
                let cLon = (minLon + maxLon) / 2
                let dLat = (cLat - center.latitude) * 111_111.0
                let dLon = (cLon - center.longitude) * 111_111.0 * cos(cLat * .pi / 180)
                let halfDiag = (latStep * 111_111.0 * 0.71) // ~half of √2·cell
                if (dLat * dLat + dLon * dLon).squareRoot() <= radiusMeters + halfDiag {
                    cells.append(GridCell(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon))
                }
            }
        }
        return cells
    }

    private func countRoads(center: CLLocationCoordinate2D, radiusMeters: Double) -> Int {
        HERELocalBatchCache.shared.countInZone(center: center, radiusMeters: radiusMeters)
    }

    // MARK: - maxspeed parsing (shared with OverpassSpeedLimitProvider)

    /// Parse an OSM `maxspeed` value into mph. Handles "mph", "km/h", "kmh"
    /// suffixes and bare numeric values. Tolerates parenthetical context like
    /// "30 mph (truck)" — only the leading numeric prefix is consumed.
    public static func mph(fromMaxspeed raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let isKmh = trimmed.contains("km/h") || trimmed.contains("kmh") || trimmed.contains("kph")
        var digits = ""
        for ch in trimmed {
            if ch.isNumber || ch == "." { digits.append(ch) }
            else if !digits.isEmpty { break }
        }
        guard let n = Double(digits), n > 0, n <= 200 else { return nil }
        return isKmh ? Int((n * 0.621371).rounded()) : Int(n.rounded())
    }
}
