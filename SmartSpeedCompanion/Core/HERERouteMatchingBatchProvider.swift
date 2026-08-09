// HERERouteMatchingBatchProvider.swift
// Generates a GPS trace of up to 500 coordinate points, POSTs it as CSV to
// the HERE Route Matching API v8, parses the matched road segments and their
// speed limits, and caches each segment as a CachedRoad row in the SQLite
// cache (road_name, direction, speed_limit, lat, lon).
//
// ENDPOINT
// ─────────
//   POST https://routematching.hereapi.com/v8/match/routelinks
//     ?apiKey={key}
//     &routeMatch=1
//     &mode=fastest;car
//     &attributes=SPEED_LIMITS_FCn(FROM_REF_SPEED_LIMIT)
//
// HOW CACHING WORKS
// ──────────────────
// For each matched link in the API response:
//   1. Extract the road name (e.g., "I-10", "Baseline Rd")
//   2. Compute the direction from the link's geometry bearing
//   3. Extract the speed limit from matched link attributes
//   4. Record the midpoint coordinate of the link's GeoJSON geometry
//      (`[longitude, latitude]` → `CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])`)
//   5. Insert a CachedRoad row into the SQLite cache
//
// When the user later drives on the same road, SpeedLimitService
// looks up by road name + direction (fast) or spatial nearest-neighbor.
//
// Grid generation: 21×21 = 441 points at ~150m spacing, ~3km × 3km area.
// No overlapping center points (unlike spiderweb).
//
// PRICING
// ────────
// Each POST counts as 1–5 Freemium transactions (attributes cost extra).
// At 250k/month, that's 50k+ batch fetches.

import Foundation
import CoreLocation

public final class HERERouteMatchingBatchProvider: @unchecked Sendable {
    public init() {}

    private let gridCols: Int = 21
    private let gridRows: Int = 21
    private let gridSpacingMeters: Double = 150
    private let minBatchInterval: TimeInterval = 30

    private let lock = NSLock()
    private var _lastBatchFetchAt: Date?

    // MARK: - Public API

    /// Generate a rectangular grid of points around the center coordinate,
    /// POST to the HERE Route Matching API, parse matched road segments with
    /// speed limits, and cache each segment in the SQLite cache.
    ///
    /// - Parameters:
    ///   - center: User's current location.
    ///   - radiusMeters: Maximum radius. Default 1500m (3km × 3km area).
    /// - Returns: Number of unique road segments cached.
    @discardableResult
    public func fetchAndCacheGrid(
        around center: CLLocationCoordinate2D,
        radiusMeters: Double = 1500
    ) async throws -> Int {
        // ── 1. Throttle gate ─────────────────────────────────────────
        guard claimBatchFetchSlot() else {
            DebugLogger.shared.log("HERE Batch: throttle — skipping")
            return 0
        }

        // ── 2. Build the CSV trace ───────────────────────────────────
        let tracePoints = generateRectangularGrid(
            center: center,
            radiusMeters: radiusMeters
        )
        let csvBody = buildCSV(from: tracePoints)
        guard !csvBody.isEmpty else { return 0 }

        DebugLogger.shared.log("HERE Batch: POSTing \(tracePoints.count)-point grid")

        // ── 3. Build request ─────────────────────────────────────────
        guard let creds = HERECredentialStore.shared.loadCredentials() else {
            DebugLogger.shared.log("HERE Batch: no credentials")
            return 0
        }

        var components = URLComponents(string: "https://routematching.hereapi.com/v8/match/routelinks")
        components?.queryItems = [
            URLQueryItem(name: "apiKey", value: creds.accessKeyId),
            URLQueryItem(name: "routeMatch", value: "1"),
            URLQueryItem(name: "mode", value: "fastest;car"),
            URLQueryItem(name: "attributes", value: "SPEED_LIMITS_FCn(FROM_REF_SPEED_LIMIT)"),
        ]
        guard let url = components?.url else { return 0 }

        var request = URLRequest(url: url, timeoutInterval: 15.0)
        request.httpMethod = "POST"
        request.setValue("text/csv", forHTTPHeaderField: "Content-Type")
        request.setValue("Speedio/2.2", forHTTPHeaderField: "User-Agent")
        request.httpBody = csvBody.data(using: .utf8)

        // ── 4. Execute ───────────────────────────────────────────────
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            DebugLogger.shared.log("HERE Batch: HTTP \(code)")
            throw URLError(.badServerResponse)
        }

        // ── 5. Parse response → build CachedRoad array ───────────────
        let roads = try parseResponseToCachedRoads(data: data)
        guard !roads.isEmpty else {
            DebugLogger.shared.log("HERE Batch: parsed 0 road segments")
            return 0
        }

        // ── 6. Cache into SQLite ─────────────────────────────────────
        // store() is thread-safe via its own serial queue — no need to
        // hop to any actor.
        HERELocalBatchCache.shared.store(roads: roads)
        DebugLogger.shared.log("HERE Batch: cached \(roads.count) road segments")
        return roads.count
    }

    private func claimBatchFetchSlot() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if let last = _lastBatchFetchAt,
           Date().timeIntervalSince(last) < minBatchInterval {
            return false
        }
        _lastBatchFetchAt = Date()
        return true
    }

    // MARK: - Grid Generation

    private func generateRectangularGrid(
        center: CLLocationCoordinate2D,
        radiusMeters: Double
    ) -> [CLLocationCoordinate2D] {
        let centerLoc = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let halfSpan = min(radiusMeters, Double(gridCols / 2) * gridSpacingMeters)
        var points: [CLLocationCoordinate2D] = []

        for row in 0..<gridRows {
            let dLat = (Double(row) - Double(gridRows - 1) / 2.0) * gridSpacingMeters
            for col in 0..<gridCols {
                let dLon = (Double(col) - Double(gridCols - 1) / 2.0) * gridSpacingMeters
                let dist = sqrt(dLat * dLat + dLon * dLon)
                guard dist <= halfSpan else { continue }
                let bearing = atan2(dLon, dLat) * 180.0 / .pi
                points.append(centerLoc.location(at: dist, bearing: bearing).coordinate)
            }
        }
        return points
    }

    private func buildCSV(from points: [CLLocationCoordinate2D]) -> String {
        var csv = "latitude,longitude\n"
        for p in points {
            csv += String(format: "%.6f,%.6f\n", p.latitude, p.longitude)
        }
        return csv
    }

    // MARK: - Response Parsing → CachedRoad

    /// Parse the HERE Route Matching API response and produce an array of
    /// CachedRoad values for each matched link.
    ///
    /// Expected response structure:
    /// {
    ///   "routes": [{
    ///     "sections": [{
    ///       "matchedLinks": [{
    ///         "linkId": "12345",
    ///         "roadName": "I-10",
    ///         "functionalClass": 1,
    ///         "speedLimits": { "fromRefSpeedLimit": 29.0576 },
    ///         "geometry": { "coordinates": [[lat, lon], [lat, lon], ...] }
    ///       }]
    ///     }]
    ///   }]
    /// }
    private func parseResponseToCachedRoads(data: Data) throws -> [CachedRoad] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var roads: [CachedRoad] = []
        // Track seen (roadName, direction, speedLimitMph, lat, lon) tuples
        // to avoid inserting duplicate rows for the same road segment.
        var seen: Set<String> = []

        guard let routes = json["routes"] as? [[String: Any]] else { return [] }

        for route in routes {
            guard let sections = route["sections"] as? [[String: Any]] else { continue }
            for section in sections {
                let sectionRoads = parseSectionLinks(section, seen: &seen)
                roads.append(contentsOf: sectionRoads)
            }
        }

        return roads
    }

    /// Extract CachedRoad values from a single section's matchedLinks.
    private func parseSectionLinks(
        _ section: [String: Any],
        seen: inout Set<String>
    ) -> [CachedRoad] {
        guard let matchedLinks = section["matchedLinks"] as? [[String: Any]],
              !matchedLinks.isEmpty else { return [] }

        var roads: [CachedRoad] = []

        for link in matchedLinks {
            guard let roadName = roadName(from: link),
                  !roadName.isEmpty else { continue }

            // ── Extract speed limit (m/s → mph) ─────────────────────
            // Use only the link's forward/reference-direction limit. The
            // reverse (`toRef`) value belongs to the opposite travel direction
            // and cannot be used unless the trace direction is explicitly
            // matched to it. Returning no data is safer than caching the
            // opposite side of a divided road or a different directional zone.
            let speedMs = speedLimitMetersPerSecond(in: link)
            // Do not fall back to a section-level value for a link without
            // its own speed-limit attributes. A section may contain several
            // matched links at an intersection; smearing one link's 25 mph
            // value across the entire section is how an arterial can inherit
            // a nearby residential limit.
            guard let spd = speedMs, spd > 0 else { continue }
            let mph = Int((spd * 2.23694).rounded())
            guard mph > 0, mph <= 90 else { continue }

            // ── Extract geometry and compute midpoint + direction ────
            var geometryCoords: [CLLocationCoordinate2D] = []

            // Try "geometry.coordinates" (GeoJSON format)
            if let geometry = link["geometry"] as? [String: Any] {
                geometryCoords = coordinates(from: geometry["coordinates"])
            }

            // Never reuse section geometry for a link. That geometry may span
            // multiple links and would place every link at the same midpoint,
            // allowing a nearby 25 mph link to masquerade as the current road.
            //
            // No link geometry available — skip silently
            // (the live provider chain will handle single-point lookups).
            guard !geometryCoords.isEmpty else { continue }

            // ── Compute direction from geometry bearing ──────────────
            let direction = computeDirection(from: geometryCoords)

            // ── Store midpoint coordinate ────────────────────────────
            let midIndex = geometryCoords.count / 2
            let midCoord = geometryCoords[midIndex]

            // ── Dedup: skip if we already have this (name, dir, mph, coord) ──
            let dedupKey = "\(roadName)|\(direction)|\(mph)|\(String(format: "%.4f,%.4f", midCoord.latitude, midCoord.longitude))"
            guard seen.insert(dedupKey).inserted else { continue }

            let road = CachedRoad(
                roadName: roadName,
                direction: direction,
                speedLimitMph: mph,
                latitude: midCoord.latitude,
                longitude: midCoord.longitude,
                source: "here"
            )
            roads.append(road)
        }

        return roads
    }

    private func roadName(from link: [String: Any]) -> String? {
        if let direct = link["roadName"] as? String, !direct.isEmpty {
            return direct
        }
        let attributes = link["attributes"] as? [String: Any] ?? [:]
        if let direct = attributes["roadName"] as? String, !direct.isEmpty {
            return direct
        }
        for container in [link, attributes] {
            if let names = container["names"] as? [[String: Any]] {
                if let value = names.compactMap({ $0["value"] as? String ?? $0["name"] as? String }).first(where: { !$0.isEmpty }) {
                    return value
                }
            }
            if let names = container["names"] as? [String],
               let value = names.first(where: { !$0.isEmpty }) {
                return value
            }
        }
        return nil
    }

    /// Extract the forward/reference-direction speed limit from one matched
    /// link. JSONSerialization may bridge integer and floating-point values to
    /// NSNumber, so do not rely on `as? Double` for this boundary.
    private func speedLimitMetersPerSecond(in link: [String: Any]) -> Double? {
        // HERE has returned this attribute both directly on a matched link and
        // inside an `attributes`/`speedLimits` object. Search those containers
        // recursively, but only accept the forward/reference-direction field.
        // Never substitute TO_REF_SPEED_LIMIT: it describes the opposite travel
        // direction and the trace does not prove that direction here.
        return forwardSpeedLimit(in: link)
    }

    private func forwardSpeedLimit(in object: [String: Any], depth: Int = 0) -> Double? {
        guard depth < 4 else { return nil }
        for (key, value) in object {
            let normalizedKey = key
                .uppercased()
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
            if normalizedKey.contains("FROMREFSPEEDLIMIT"),
               let number = numericValue(value), number > 0 {
                return number
            }
            if let nested = value as? [String: Any],
               let number = forwardSpeedLimit(in: nested, depth: depth + 1) {
                return number
            }
        }
        return nil
    }

    private func numericValue(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let number = value as? NSNumber {
            let result = number.doubleValue
            return result.isFinite ? result : nil
        }
        if let number = value as? Double, number.isFinite { return number }
        if let number = value as? Int { return Double(number) }
        return nil
    }

    private func coordinates(from value: Any?) -> [CLLocationCoordinate2D] {
        guard let pairs = value as? [[Any]] else {
            if let pairs = value as? [[Double]] {
                return pairs.compactMap { pair in
                    guard pair.count >= 2 else { return nil }
                    return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
                }
            }
            return []
        }
        return pairs.compactMap { pair in
            guard pair.count >= 2,
                  let longitude = numericValue(pair[0]),
                  let latitude = numericValue(pair[1]),
                  longitude.isFinite, latitude.isFinite else { return nil }
            // HERE returns GeoJSON positions in [longitude, latitude] order.
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    /// Compute the cardinal direction from an array of geometry coordinates.
    /// Uses the bearing between the first and last point.
    private func computeDirection(from coords: [CLLocationCoordinate2D]) -> String {
        guard coords.count >= 2 else { return "" }
        let first = coords.first!
        let last = coords.last!
        let dLat = last.latitude - first.latitude
        let dLon = last.longitude - first.longitude

        guard sqrt(dLat * dLat + dLon * dLon) > 0.0001 else { return "" } // too short to infer

        let bearing = atan2(dLon, dLat) * 180.0 / .pi
        let normalized = ((bearing.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360)

        if normalized < 45 || normalized >= 315 { return "N" }
        if normalized < 135 { return "E" }
        if normalized < 225 { return "S" }
        return "W"
    }
}

// MARK: - CLLocation Bearing Extension

extension CLLocation {
    /// Returns a new CLLocation at a given distance (meters) and bearing
    /// (degrees, 0 = north, 90 = east) from this location.
    func location(at distance: CLLocationDistance, bearing: Double) -> CLLocation {
        let lat1 = self.coordinate.latitude * .pi / 180
        let lon1 = self.coordinate.longitude * .pi / 180
        let bearingRad = bearing * .pi / 180
        let R = 6_371_000.0
        let lat2 = asin(sin(lat1) * cos(distance / R) +
                        cos(lat1) * sin(distance / R) * cos(bearingRad))
        let lon2 = lon1 + atan2(
            sin(bearingRad) * sin(distance / R) * cos(lat1),
            cos(distance / R) - sin(lat1) * sin(lat2)
        )
        return CLLocation(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
    }
}
