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
//     &filetype=CSV
//     &routeMatch=1
//     &mode=fastest;car
//     &attributes=SPEED_LIMITS_FCn(FROM_REF_SPEED_LIMIT),ROAD_NAME_FCn(*)
//
// Route Matching returns a `RouteLinks` array. Each link carries its shape
// as a whitespace-separated latitude/longitude sequence and its requested
// layer attributes under `attributes`.
//
// Route Matching returns FROM_REF_SPEED_LIMIT in KPH. It is not the m/s
// unit used by the Routing API span response.
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
            // The body is a CSV trace. Without filetype=CSV the v8 endpoint
            // may accept the request but return no matched route links.
            URLQueryItem(name: "filetype", value: "CSV"),
            URLQueryItem(name: "routeMatch", value: "1"),
            URLQueryItem(name: "mode", value: "fastest;car"),
            // Request both the forward speed limit and road name. RouteLinks
            // does not include a usable display road name unless ROAD_NAME_FCn
            // is explicitly requested.
            URLQueryItem(name: "attributes", value: "SPEED_LIMITS_FCn(FROM_REF_SPEED_LIMIT),ROAD_NAME_FCn(*)"),
        ]
        guard let url = components?.url else { return 0 }

        var request = URLRequest(url: url, timeoutInterval: 15.0)
        request.httpMethod = "POST"
        request.setValue("text/csv", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
    /// Expected Route Matching response structure:
    /// {
    ///   "RouteLinks": [{
    ///     "linkId": 12345,
    ///     "shape": "33.4 -111.9 33.401 -111.901",
    ///     "attributes": {
    ///       "SPEED_LIMITS_FCn": [{ "FROM_REF_SPEED_LIMIT": "65" }],
    ///       "ROAD_NAME_FCn": [{ "NAMES": "Main St" }]
    ///     }
    ///   }]
    /// }
    ///
    /// A defensive parser for the older routes/sections/matchedLinks shape is
    /// retained below so a backend response-format transition cannot erase all
    /// cache coverage at once.
    private func parseResponseToCachedRoads(data: Data) throws -> [CachedRoad] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var roads: [CachedRoad] = []
        // Track seen (roadName, direction, speedLimitMph, lat, lon) tuples
        // to avoid inserting duplicate rows for the same road segment.
        var seen: Set<String> = []

        // This is the actual Route Matching v8 response shape. The previous
        // parser only looked for Routing API's routes/sections shape, so every
        // batch response was parsed as zero roads and the local HERE cache
        // stayed empty.
        if let routeLinks = json["RouteLinks"] as? [[String: Any]] {
            roads.append(contentsOf: parseRouteLinks(routeLinks, seen: &seen))
        }

        // Defensive compatibility with an older routes/sections response.
        if let routes = json["routes"] as? [[String: Any]] {
            for route in routes {
                guard let sections = route["sections"] as? [[String: Any]] else { continue }
                for section in sections {
                    roads.append(contentsOf: parseSectionLinks(section, seen: &seen))
                }
            }
        }

        return roads
    }

    /// Extract CachedRoad values from a RouteLinks array.
    private func parseRouteLinks(
        _ links: [[String: Any]],
        seen: inout Set<String>
    ) -> [CachedRoad] {
        var roads: [CachedRoad] = []
        for link in links {
            guard let road = parseCachedRoad(from: link) else { continue }
            let dedupKey = "\(road.roadName)|\(road.direction)|\(road.speedLimitMph)|\(String(format: "%.4f,%.4f", road.latitude, road.longitude))"
            guard seen.insert(dedupKey).inserted else { continue }
            roads.append(road)
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
        return parseRouteLinks(matchedLinks, seen: &seen)
    }

    private func parseCachedRoad(from link: [String: Any]) -> CachedRoad? {
        guard let roadName = roadName(from: link),
              !roadName.isEmpty,
              let speedKph = speedLimitKilometersPerHour(in: link),
              speedKph > 0 else { return nil }

        // Route Matching's SPEED_LIMITS_FCn layer reports
        // FROM_REF_SPEED_LIMIT in KPH. The live Routing API uses m/s,
        // but applying that conversion here turns a normal 50 KPH value
        // into an impossible 112 MPH value that is then rejected.
        let mph = Int((speedKph * 0.621371).rounded())
        guard mph > 0, mph <= 90 else { return nil }

        // RouteLinks uses a whitespace-separated "lat lon" shape. The
        // defensive GeoJSON path keeps compatibility with the older parser
        // shape used by some proxy deployments.
        let geometryCoords = geometryCoordinates(from: link)
        guard !geometryCoords.isEmpty else { return nil }

        let direction = computeDirection(from: geometryCoords)
        let midCoord = geometryCoords[geometryCoords.count / 2]
        return CachedRoad(
            roadName: roadName,
            direction: direction,
            speedLimitMph: mph,
            latitude: midCoord.latitude,
            longitude: midCoord.longitude,
            source: "here"
        )
    }

    private func geometryCoordinates(from link: [String: Any]) -> [CLLocationCoordinate2D] {
        if let geometry = link["geometry"] as? [String: Any] {
            let coords = coordinates(from: geometry["coordinates"])
            if !coords.isEmpty { return coords }
        }
        let coords = coordinates(from: link["coordinates"])
        if !coords.isEmpty { return coords }
        if let shape = link["shape"] as? String {
            return coordinates(fromRouteLinkShape: shape)
        }
        return []
    }

    private func coordinates(fromRouteLinkShape shape: String) -> [CLLocationCoordinate2D] {
        let values = shape
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { Double($0) }
        guard values.count >= 4 else { return [] }

        var result: [CLLocationCoordinate2D] = []
        for index in stride(from: 0, through: values.count - 2, by: 2) {
            let latitude = values[index]
            let longitude = values[index + 1]
            guard (-90.0...90.0).contains(latitude),
                  (-180.0...180.0).contains(longitude) else { return [] }
            result.append(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        }
        return result
    }

    private func roadName(from link: [String: Any]) -> String? {
        for key in ["roadName", "road_name", "name", "names"] {
            if let name = textValue(link[key]) {
                return name
            }
        }

        let attributes = link["attributes"] as? [String: Any] ?? [:]
        for key in ["roadName", "road_name", "name", "names"] {
            if let name = textValue(attributes[key]) {
                return name
            }
        }

        // Route Matching returns requested map layers with names such as
        // ROAD_NAME_FCn. The layer value is normally an array of dictionaries
        // containing NAMES, but accepting the other common scalar/dictionary
        // shapes makes the cache resilient to HERE schema variants.
        for (key, value) in attributes {
            let normalizedKey = key
                .uppercased()
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
            if normalizedKey.contains("ROADNAME"),
               let name = textValue(value) {
                return name
            }
        }
        return nil
    }

    private func textValue(_ value: Any?, depth: Int = 0) -> String? {
        guard depth < 5 else { return nil }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let object = value as? [String: Any] {
            // Prefer human-readable name fields over metadata such as language
            // codes or link identifiers.
            for key in ["NAMES", "NAME", "ROAD_NAME", "roadName", "name", "value", "VALUE"] {
                if let result = textValue(object[key], depth: depth + 1) {
                    return result
                }
            }
            for child in object.values {
                if let result = textValue(child, depth: depth + 1) {
                    return result
                }
            }
        }
        if let objects = value as? [[String: Any]] {
            for object in objects {
                if let result = textValue(object, depth: depth + 1) {
                    return result
                }
            }
        }
        if let values = value as? [Any] {
            for child in values {
                if let result = textValue(child, depth: depth + 1) {
                    return result
                }
            }
        }
        return nil
    }

    /// Extract the forward/reference-direction speed limit from one matched
    /// link. Route Matching's SPEED_LIMITS_FCn values are KPH.
    private func speedLimitKilometersPerHour(in link: [String: Any]) -> Double? {
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
            if let nested = value as? [[String: Any]] {
                for item in nested {
                    if let number = forwardSpeedLimit(in: item, depth: depth + 1) {
                        return number
                    }
                }
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
        // Route Matching has historically encoded layer attributes such as
        // FROM_REF_SPEED_LIMIT as JSON strings (for example "50").
        if let string = value as? String,
           let number = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)),
           number.isFinite {
            return number
        }
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
