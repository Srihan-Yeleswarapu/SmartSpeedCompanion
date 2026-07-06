// OverpassSpeedLimitProvider.swift
// Live speed-limit provider backed by the Overpass API, querying OpenStreetMap for
// ways with a `highway` tag and `maxspeed` tag near the user.
//
// Query (POST to overpass-api.de/api/interpreter):
//   [out:json][timeout:10];
//   way(around:100,<lat>,<lon>)[highway][maxspeed];
//   out tags center 1;
//
// Notes:
//   - We use `around:100` (100m radius) instead of 30m so a successful query covers
//     the driver through several subsequent 15m fetches → cache hit rate is much higher.
//   - Overpass published throttle is 2 req/sec/IP. We honor this with a hard 60-second
//     backoff window after a 429 response — further queries in that window return nil
//     so the orchestrator falls through to the SQLite fallback.
//   - `maxspeed` value parsing handles "25 mph", "40", "60 km/h", "50 kmh", etc.
//     km/h values are converted to mph so downstream consumers always see mph.

import Foundation
import CoreLocation

public final class OverpassSpeedLimitProvider: SpeedLimitProvider, @unchecked Sendable {
    public let displayName: String = "Overpass"

    private var lastSuccessLocation: CLLocation?
    private let successMinDistance: CLLocationDistance = 100  // m

    /// After a 429, ignore Overpass for `throttleWindow` seconds.
    private var throttledUntil: Date?
    private let throttleWindow: TimeInterval = 60

    public init() {}

    public func fetchSpeedLimit(
        at coordinate: CLLocationCoordinate2D,
        heading: Double?
    ) async throws -> SpeedLimitResponse? {
        // Throttle gate.
        if let until = throttledUntil, Date() < until { return nil }
        if let last = lastSuccessLocation {
            let dist = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                .distance(from: last)
            if dist < successMinDistance { return nil }
        }

        let query = """
        [out:json][timeout:10];
        way(around:100,\(coordinate.latitude),\(coordinate.longitude))[highway][maxspeed];
        out tags center 1;
        """

        guard let url = URL(string: "https://overpass-api.de/api/interpreter") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 4.0)
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
            throw error
        }

        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if http.statusCode == 429 {
            throttledUntil = Date().addingTimeInterval(throttleWindow)
            DebugLogger.shared.log("Overpass: HTTP 429; throttling for \(Int(throttleWindow))s")
            return nil
        }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = parsed["elements"] as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }

        // Pick the closest element with a parseable maxspeed.
        var bestMph: Int? = nil
        var bestOsmId: String? = nil
        var bestDist: Double = .greatestFiniteMagnitude

        let lat1 = coordinate.latitude * .pi / 180
        for el in elements {
            guard let id = el["id"] as? Int,
                  let tags = el["tags"] as? [String: Any],
                  let raw = tags["maxspeed"] as? String,
                  let mph = parseMaxspeed(raw) else { continue }

            var lat: Double? = nil
            var lon: Double? = nil
            if let center = el["center"] as? [String: Any] {
                lat = center["lat"] as? Double
                lon = center["lon"] as? Double
            } else if let la = el["lat"] as? Double, let lo = el["lon"] as? Double {
                lat = la; lon = lo
            }
            guard let elLat = lat, let elLon = lon else { continue }

            let dLat = (elLat - coordinate.latitude) * .pi / 180
            let dLon = (elLon - coordinate.longitude) * .pi / 180
            let a = sin(dLat / 2) * sin(dLat / 2) +
                    cos(lat1) * cos(elLat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
            let c = 2 * atan2(sqrt(a), sqrt(1 - a))
            let distMeters = 6_378_137.0 * c

            if distMeters < bestDist {
                bestDist = distMeters
                bestMph = mph
                bestOsmId = "\(id)"
            }
        }

        guard let mph = bestMph, let osmId = bestOsmId else { return nil }
        lastSuccessLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let highway = (elements.first?["tags"] as? [String: Any])?["highway"] as? String
        let detail = highway.map { "OSM way \(osmId) (\($0), \(mph) mph)" } ?? "OSM way \(osmId)"
        return SpeedLimitResponse(
            speedLimitMph: mph,
            roadKey: "way\(osmId)",
            providerName: displayName,
            detail: detail
        )
    }

    // MARK: - Parsing

    /// Parse an OSM `maxspeed` value into mph. Handles "mph", "km/h", "kmh" suffixes
    /// and bare numeric values (treated as mph by convention). Also tolerates
    /// parenthetical context like "30 mph (truck)" or "ROAD TYPE: 30 mph" — we
    /// only consume the leading numeric prefix.
    private func parseMaxspeed(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let isKmh = trimmed.contains("km/h") || trimmed.contains("kmh") || trimmed.contains("kph")
        let numericPrefix: Int? = {
            var digits = ""
            for ch in trimmed {
                if ch.isNumber || ch == "." { digits.append(ch) }
                else if !digits.isEmpty { break }
                // Skip leading non-digits until a digit appears.
            }
            guard let n = Double(digits), n > 0, n <= 200 else { return nil }
            return isKmh ? Int((n * 0.621371).rounded()) : Int(n.rounded())
        }()
        return numericPrefix
    }
}
