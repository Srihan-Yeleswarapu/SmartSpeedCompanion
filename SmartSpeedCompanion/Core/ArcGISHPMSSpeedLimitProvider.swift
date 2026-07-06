// ArcGISHPMSSpeedLimitProvider.swift
// Live speed-limit provider backed by the publicly-readable ArcGIS FeatureServer
// layer 48 (HPMS_2024_Data / SpeedLimit_2024) for Arizona.
//
// Endpoint contract (validated end-to-end):
//   https://services6.arcgis.com/clPWQMwZfdWn4MQZ/arcgis/rest/services/
//     HPMS_2024_Data/FeatureServer/48/query
//     ?f=json
//     &geometry={"x":<lon>,"y":<lat>}
//     &geometryType=esriGeometryPoint
//     &inSR=4326
//     &spatialRel=esriSpatialRelIntersects
//     &outFields=OBJECTID,SpeedLimit,SRNumber,SpeedLimitDirection_Value,SpeedLimitType_Value
//     &returnGeometry=true
//
// Response shape:
//     { "features": [{ "attributes": { OBJECTID, SpeedLimit, SRNumber,
//                                       SpeedLimitDirection_Value,
//                                       SpeedLimitType_Value },
//                       "geometry": { "paths": [[[lon,lat],[lon,lat], ...]] } }] }
//
// Coverage caveats:
//   - AZ-only extent (XMin -114.95, XMax -108.87, YMin 31.30, YMax 37.03).
//   - Only FHWA "sample panel sections" → most local streets return no features.
// These are expected and surfaced to the orchestrator as `return nil` (the orchestrator
// walks the next provider in the live chain).
//
// Self-throttling:
//   - Success: drops further queries within 100m / 0s of the last successful call.
//   - Failure: drops further queries within 10s of the last failure.

import Foundation
import CoreLocation

public final class ArcGISHPMSSpeedLimitProvider: SpeedLimitProvider, @unchecked Sendable {
    public let displayName: String = "ArcGIS"

    // Per-provider throttle state (only mutated from the provider's async context,
    // so even though `@unchecked Sendable` is used, accesses are funneled through
    // the serial executor of the calling Task).
    private var lastSuccessLocation: CLLocation?
    private var lastFailureAt: Date?
    private let successMinDistance: CLLocationDistance = 100
    private let failureRetryInterval: TimeInterval = 10

    private struct QueryResponse: Decodable {
        let features: [Feature]
        struct Feature: Decodable {
            let attributes: Attributes
            let geometry: Geometry?
            struct Attributes: Decodable {
                let OBJECTID: Int?
                let SpeedLimit: Int?
                let SRNumber: String?
                let SpeedLimitDirection_Value: String?
                let SpeedLimitType_Value: String?
            }
            struct Geometry: Decodable {
                let paths: [[[Double]]]?  // array of paths, each path is array of [lon, lat]
            }
        }
    }

    public init() {}

    public func fetchSpeedLimit(
        at coordinate: CLLocationCoordinate2D,
        heading: Double?
    ) async throws -> SpeedLimitResponse? {
        // Self-throttle.
        if let last = lastSuccessLocation {
            let dist = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                .distance(from: last)
            if dist < successMinDistance { return nil }
        }
        if let lastFail = lastFailureAt, Date().timeIntervalSince(lastFail) < failureRetryInterval {
            return nil
        }

        guard let url = makeURL(lat: coordinate.latitude, lon: coordinate.longitude) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 2.0)
        request.httpMethod = "GET"

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            lastFailureAt = Date()
            throw error
        }

        guard let http = response as? HTTPURLResponse else {
            lastFailureAt = Date()
            throw URLError(.badServerResponse)
        }
        if http.statusCode == 429 {
            lastFailureAt = Date()
            throw URLError(.resourceUnavailable)
        }
        guard (200..<300).contains(http.statusCode) else {
            lastFailureAt = Date()
            throw URLError(.badServerResponse)
        }

        let parsed: QueryResponse
        do {
            parsed = try JSONDecoder().decode(QueryResponse.self, from: data)
        } catch {
            lastFailureAt = Date()
            throw error
        }

        guard !parsed.features.isEmpty,
              let bestIdx = bestFeatureIndex(parsed.features, currentCoord: coordinate, heading: heading),
              let limit = parsed.features[bestIdx].attributes.SpeedLimit,
              limit > 0 else {
            // Genuinely no record — sample-panel gap or out-of-AZ. Not an error to retry.
            lastFailureAt = Date()
            return nil
        }
        let attrs = parsed.features[bestIdx].attributes

        lastSuccessLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let sr = attrs.SRNumber ?? "?"
        let dir = attrs.SpeedLimitDirection_Value ?? "?"
        let kind = attrs.SpeedLimitType_Value ?? "Speed Limit"
        return SpeedLimitResponse(
            speedLimitMph: limit,
            roadKey: "SR\(sr)-\(dir)",
            providerName: displayName,
            detail: "\(kind); SR \(sr) \(dir)"
        )
    }

    // MARK: - Private helpers

    private func makeURL(lat: Double, lon: Double) -> URL? {
        let geomJson = String(format: "{\"x\":%.6f,\"y\":%.6f}", lon, lat)
        var components = URLComponents(string:
            "https://services6.arcgis.com/clPWQMwZfdWn4MQZ/arcgis/rest/services/HPMS_2024_Data/FeatureServer/48/query"
        )!
        components.queryItems = [
            URLQueryItem(name: "f", value: "json"),
            URLQueryItem(name: "geometry", value: geomJson),
            URLQueryItem(name: "geometryType", value: "esriGeometryPoint"),
            URLQueryItem(name: "inSR", value: "4326"),
            URLQueryItem(name: "spatialRel", value: "esriSpatialRelIntersects"),
            URLQueryItem(name: "outFields", value: "OBJECTID,SpeedLimit,SRNumber,SpeedLimitDirection_Value,SpeedLimitType_Value"),
            URLQueryItem(name: "returnGeometry", value: "true"),
            URLQueryItem(name: "resultRecordCount", value: "10"),
        ]
        return components.url
    }

    /// Earth radius used by every Haversine in this provider. Local static to avoid
    /// capturing `self` (which would need explicit Sendable threading).
    private static let earthRadiusMeters: Double = 6_378_137.0

    /// Score a feature: smaller is better. Combines polyline proximity with heading-vs-
    /// direction penalty. We deliberately score ALL features even if some lack a
    /// `SpeedLimitDirection_Value` (undivided highway), so they don't get excluded.
    private func bestFeatureIndex(
        _ features: [QueryResponse.Feature],
        currentCoord: CLLocationCoordinate2D,
        heading: Double?
    ) -> Int? {
        var bestScore: Double = .greatestFiniteMagnitude
        var bestIdx: Int? = nil

        for (idx, feature) in features.enumerated() {
            guard (feature.attributes.SpeedLimit ?? 0) > 0 else { continue }

            // Closest vertex of any path in this feature, in meters (Haversine).
            let minDistMeters = closestVertexDistance(feature: feature, to: currentCoord)
            var score = minDistMeters + 1.0  // +1 base so heading multipliers still bite at 0m.

            // Heading-vs-direction penalty. The map:
            //   "NB" → 0°, "EB" → 90°, "SB" → 180°, "WB" → 270°.
            //   "NB/SB" or "EB/WB" → no penalty (matches either direction).
            if let dirString = feature.attributes.SpeedLimitDirection_Value,
               let roadHeading = matchCardinal(dirString),
               let carHeading = heading {
                let diff = abs(normalizeAngle(carHeading - roadHeading))
                if diff > 90 {
                    score *= 10.0  // heavy opposite-direction penalty
                } else if diff > 40 {
                    score *= 3.0
                }
            }
            if score < bestScore {
                bestScore = score
                bestIdx = idx
            }
        }
        return bestIdx
    }

    /// Haversine distance (m) from `coord` to the nearest `[lon,lat]` vertex of any path
    /// in the feature. Falls back to 75m when the feature has no geometry (so it can
    /// still be considered but with a penalty).
    private func closestVertexDistance(
        feature: QueryResponse.Feature,
        to coord: CLLocationCoordinate2D
    ) -> Double {
        guard let paths = feature.geometry?.paths else { return 75.0 }
        var minDist: Double = .greatestFiniteMagnitude
        let lat1 = coord.latitude * .pi / 180
        for path in paths {
            for pair in path where pair.count >= 2 {
                let lon2 = pair[0]
                let lat2 = pair[1] * .pi / 180
                let dLat = lat2 - lat1
                let dLon = (lon2 - coord.longitude) * .pi / 180
                let a = sin(dLat / 2) * sin(dLat / 2) +
                        cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
                let c = 2 * atan2(sqrt(a), sqrt(1 - a))
                let meters = ArcGISHPMSSpeedLimitProvider.earthRadiusMeters * c
                if meters < minDist { minDist = meters }
            }
        }
        return minDist
    }

    /// Map a `SpeedLimitDirection_Value` string to a cardinal heading (degrees from N).
    /// Returns nil for "NB/SB", "EB/WB", or unrecognized — caller won't apply a penalty.
    private func matchCardinal(_ s: String) -> Double? {
        let u = s.uppercased()
        if u.contains("NB") && !u.contains("SB") { return 0 }
        if u.contains("SB") && !u.contains("NB") { return 180 }
        if u.contains("EB") && !u.contains("WB") { return 90 }
        if u.contains("WB") && !u.contains("EB") { return 270 }
        return nil
    }

    /// Normalize an angle to (-180, 180] for symmetric diff math.
    private func normalizeAngle(_ d: Double) -> Double {
        var x = d.truncatingRemainder(dividingBy: 360)
        if x > 180 { x -= 360 }
        if x <= -180 { x += 360 }
        return x
    }
}
