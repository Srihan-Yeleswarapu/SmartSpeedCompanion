// OverpassSpeedLimitProvider.swift
// Live speed-limit provider backed by the Overpass API, querying OpenStreetMap for
// ways with a `highway` tag and `maxspeed` tag near the user.
//
// Query (POST to overpass-api.de/api/interpreter):
//   [out:json][timeout:15];
//   way(around:150,<lat>,<lon>)[highway][maxspeed];
//   out geom tags 1;
//
// Notes:
//   - We use `around:150` (150m radius) so a successful query covers several
//     subsequent 15 m fetches AND has enough nearby candidates for the
//     bearing-aware pick below to discard perpendicular cross-streets.
//   - `out geom` (vs the legacy `out tags center 1`) returns each way's full
//     polyline as a `geometry: [{lat,lon},...]` array, which we use to score
//     the closest-segment bearing against the driver's heading. OSM ways are
//     bidirectional so we fold angles modulo 180° → [0, 90°] before applying
//     the cutoff (<=30° = parallel, <=60° = oblique, >60° = perpendicular).
//   - TestFlight 2.2.x feedback (Chandler AZ 45 mph arterial misread as the
//     perpendicular 25 mph cross-street): the previous closest-by-distance
//     pick would return the wrong limit whenever GPS snapped to the corner of
//     an intersection. The bearing filter resolves this.
//   - Overpass published throttle is 2 req/sec/IP. We honor this with a hard 60-second
//     backoff window after a 429 response — further queries in that window return nil
//     so the orchestrator proceeds to its normal No Data/miss path.
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
        [out:json][timeout:15];
        way(around:150,\(coordinate.latitude),\(coordinate.longitude))[highway][maxspeed];
        out geom tags 1;
        """

        guard let url = URL(string: "https://overpass-api.de/api/interpreter") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 6.0)
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

        // Build per-way candidates: maxspeed tag + polyline coords.
        // `out geom` returns `geometry: [{lat:..., lon:...}, ...]` for ways.
        // We deliberately skip ways with fewer than 2 vertices — they have no
        // measurable bearing so they can't be filtered by direction of motion.
        struct Candidate {
            let mph: Int
            let osmId: String
            let coords: [CLLocationCoordinate2D]
            let highway: String?
        }
        var candidates: [Candidate] = []
        for el in elements {
            guard let id = el["id"] as? Int,
                  let tags = el["tags"] as? [String: Any],
                  let raw = tags["maxspeed"] as? String,
                  let mph = parseMaxspeed(raw) else { continue }

            var coords: [CLLocationCoordinate2D] = []
            if let geom = el["geometry"] as? [[String: Any]] {
                coords.reserveCapacity(geom.count)
                for g in geom {
                    if let lat = g["lat"] as? Double, let lon = g["lon"] as? Double {
                        coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
                    }
                }
            }
            // Legacy fallback: if `out geom` somehow didn't attach geometry for
            // an element (shouldn't happen on `out geom tags 1`, but be
            // defensive), use the center point as a single vertex. Distance
            // scoring still works but bearing is nil → no bearing penalty.
            if coords.isEmpty {
                if let center = el["center"] as? [String: Any],
                   let lat = center["lat"] as? Double, let lon = center["lon"] as? Double {
                    coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
                    // Pad to 2 vertices so the projection math doesn't divide
                    // by zero — the synthetic pair produces an arbitrary
                    // bearing that we deliberately discard below.
                    coords.append(coords[0])
                }
            }
            guard coords.count >= 2 else { continue }

            candidates.append(Candidate(
                mph: mph, osmId: "\(id)", coords: coords,
                highway: tags["highway"] as? String
            ))
        }

        guard !candidates.isEmpty else { return nil }

        // Bearing-aware pick. Score each candidate as
        //     score = (closestSegmentDistance_m + 10 m) * bearingMultiplier
        // The +10 m base padding keeps the multiplier from being dominated by
        // a perpendicular road that happens to graze the GPS point.
        // bearingMultiplier falls into:
        //     <= 30°  → 1   (near-parallel: strongly preferred)
        //     <= 60°  → 5   (oblique)
        //     >  60°  → 50  (perpendicular: effectively rejected)
        // If heading is nil OR a way's closest-segment bearing is unavailable
        // (degenerate polyline), we only apply distance -- preserving the
        // legacy behavior in that rare case.
        var bestScore: Double = .greatestFiniteMagnitude
        var bestCandidate: Candidate? = nil
        var rejectedPerpendicular: Int = 0
        var rejectedOblique: Int = 0
        var oldestCandidateDebug: String = ""

        for c in candidates {
            let (segDist, segBearing) = closestSegment(c.coords, user: coordinate)
            guard segDist.isFinite else { continue }

            var multiplier: Double = 1
            if let userHeading = heading, let roadBearing = segBearing {
                let diff = bidirectionalAngleDiff(userHeading, roadBearing)
                if diff > 60 {
                    multiplier = 50
                    rejectedPerpendicular += 1
                } else if diff > 30 {
                    multiplier = 5
                    rejectedOblique += 1
                }
            }

            let score = (segDist + 10.0) * multiplier
            if score < bestScore {
                bestScore = score
                bestCandidate = c
                oldestCandidateDebug = "way\(c.osmId) dist=\(Int(segDist.rounded()))m x\(multiplier)"
            }
        }

        guard let winner = bestCandidate else { return nil }
        if rejectedPerpendicular > 0 || rejectedOblique > 0 {
            // Visible to TestFlight testers in the in-app debug log: makes the
            // fix attributable. Logs only when a non-trivial filter actually
            // fired (i.e. at least one candidate was demoted).
            let raw = heading.map { String(format: "%.0f°", $0) } ?? "nil"
            DebugLogger.shared.log(
                "Overpass: discarded \(rejectedPerpendicular) perp + \(rejectedOblique) oblique candidates (driver=\(raw)); chose \(oldestCandidateDebug)"
            )
        }
        let mph = winner.mph
        let osmId = winner.osmId
        lastSuccessLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let detail = winner.highway.map { "OSM way \(osmId) (\($0), \(mph) mph)" } ?? "OSM way \(osmId)"
        return SpeedLimitResponse(
            speedLimitMph: mph,
            roadKey: "way\(osmId)",
            providerName: displayName,
            detail: detail
        )
    }

    // MARK: - Bearing / distance math

    /// Project the user's coordinate onto each consecutive pair of vertices in
    /// `way`. Returns the perpendicular distance to the closest segment (m)
    /// plus the forward true-bearing of that segment (degrees clockwise from
    /// N, in [0, 360)). Bearing is nil only for a degenerate 1-vertex way.
    ///
    /// Uses a local equirectangular projection centered on the user. At a
    /// 150 m search radius the curvature error is on the order of
    /// `(150 / 6_371_000)² * 6_371_000 ≈ 0.004 m` -- far below GPS noise.
    private func closestSegment(
        _ way: [CLLocationCoordinate2D],
        user: CLLocationCoordinate2D
    ) -> (distanceMeters: Double, bearingDeg: Double?) {
        guard way.count >= 2 else { return (.greatestFiniteMagnitude, nil) }

        let cosLat = max(0.000001, cos(user.latitude * .pi / 180))
        let metersPerDegLat = 111_320.0
        let metersPerDegLon = 111_320.0 * cosLat

        var bestDist = Double.greatestFiniteMagnitude
        var bestBearing: Double? = nil

        for i in 0..<(way.count - 1) {
            let a = way[i]
            let b = way[i + 1]

            let ax = (a.longitude - user.longitude) * metersPerDegLon
            let ay = (a.latitude - user.latitude) * metersPerDegLat
            let bx = (b.longitude - user.longitude) * metersPerDegLon
            let by = (b.latitude - user.latitude) * metersPerDegLat

            let dx = bx - ax
            let dy = by - ay
            let lenSq = dx * dx + dy * dy
            guard lenSq > 1e-9 else { continue }

            // t = projection scalar of -v0 onto AB / |AB|²; clamp to [0,1] so
            // the closest point on the segment (not the line) is selected.
            var t = -((ax * dx + ay * dy) / lenSq)
            if t < 0 { t = 0 } else if t > 1 { t = 1 }

            let px = ax + t * dx
            let py = ay + t * dy
            let dist = (px * px + py * py).squareRoot()
            if dist < bestDist {
                bestDist = dist
                bestBearing = forwardBearingDegrees(from: a, to: b)
            }
        }
        return (bestDist, bestBearing)
    }

    /// Forward bearing (degrees clockwise from N, in [0, 360)) from `a` to `b`.
    private func forwardBearingDegrees(
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D
    ) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        var bearing = atan2(y, x) * 180 / .pi
        if bearing < 0 { bearing += 360 }
        return bearing
    }

    /// Smallest angle between two bidirectional lines, in degrees. The result
    /// lives in [0, 90] because roads are bidirectional: a North-South road
    /// matches a 350° driver just as well as a 10° driver (diff=10°).
    private func bidirectionalAngleDiff(_ userDeg: Double, _ roadDeg: Double) -> Double {
        var diff = (userDeg - roadDeg).truncatingRemainder(dividingBy: 180)
        if diff < 0 { diff += 180 }
        // diff is now in [0, 180). The acute (bisector) angle is min(diff,
        // 180 - diff) so perpendicular -> 90° never exceeds the 90° ceiling.
        if diff > 90 { diff = 180 - diff }
        return diff
    }

    // MARK: - Parsing

    /// Parse an OSM `maxspeed` value into mph. Delegates to the shared parser
    /// in `OfflineLimitsDownloader` (also used by the bulk "Download Limits"
    /// feature) so both Overpass consumers stay numerically consistent.
    private func parseMaxspeed(_ raw: String) -> Int? {
        OfflineLimitsDownloader.mph(fromMaxspeed: raw)
    }
}
