// HERERestSpeedLimitProvider.swift
// Primary live speed-limit provider backed by HERE Routing API v8.
//
// Endpoint contract (validated):
//   https://router.hereapi.com/v8/routes
//     ?transportMode=car
//     &origin={lat},{lon}
//     &destination={lat+dLat},{lon+dLon}  // ~35 m self-loop (wider than 5 m so
//                                         // HERE resolves the actual segment
//                                         // rather than straddle a junction).
//     &routingMode=fast
//     &return=summary,polyline
//     &units=imperial
//     &spans=names,maxSpeed
//     &apiKey={access_key_id}
//
// Speed limits are span attributes, not `return` values, and HERE ONLY
// returns spans when `return` includes `polyline` — the span offsets are
// derived from the polyline geometry ("To get spans, the request must
// include ... the return=polyline parameter"). Sending `spans=names,maxSpeed`
// without `return=polyline` makes HERE return a valid route with NO span
// attributes, so every live lookup resolves to No Data. The explicit
// imperial unit makes the returned `maxSpeed` directly usable as MPH.
// The parser still accepts the deprecated `speedLimit` object for older
// deployments.
//
// Auth: HERE Freemium tier — 250k requests/month free PERMANENTLY (NOT a
// 90-day trial). Credentials live in Keychain via HERECredentialStore.
// If credentials are missing or HERE has no coverage, this provider returns
// nil and the orchestrator shows No Data rather than silently switching to
// ArcGIS/Overpass/OSM.
//
// Throttle state is guarded by an NSLock because the provider is `final`
// non-actor — Swift concurrency allows concurrent awaiters and mutable
// lastFetch Date would otherwise race.

import Foundation
import CoreLocation
import Darwin

public final class HERERestSpeedLimitProvider: SpeedLimitProvider, @unchecked Sendable {
    public let displayName: String = "HERE REST"

    private let throttleLock = NSLock()
    private var _lastSuccess: CLLocation?
    private var _lastFailureAt: Date?
    private let successMinDistance: CLLocationDistance = 100
    private let failureRetryInterval: TimeInterval = 10
    // Probe far enough for HERE to identify the current road, but keep the
    // destination on the same segment in normal driving. The probe follows
    // the vehicle course whenever one is available.
    private let selfLoopMeters: Double = 60

    public init() {}

    public func fetchSpeedLimit(
        at coordinate: CLLocationCoordinate2D,
        heading: Double?,
        forceRefresh: Bool = false
    ) async throws -> SpeedLimitResponse? {
        // Throttle gate. The lock is accessed through synchronous helpers so
        // Swift 6 never calls NSLock.lock()/unlock() directly from this async
        // network method.
        let nowLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard !shouldSkipRequest(at: nowLoc, forceRefresh: forceRefresh) else { return nil }

        // Credentials gate. A missing key is a deployment failure, so log it
        // explicitly rather than making it indistinguishable from no map data.
        guard let creds = HERECredentialStore.shared.loadCredentials() else {
            DebugLogger.shared.log("HERE REST: credentials missing; active HERE source unavailable")
            return nil
        }
        guard !creds.accessKeyId.isEmpty else {
            DebugLogger.shared.log("HERE REST: credential value is empty")
            return nil
        }

        // Probe the road ahead by ~35 m. HERE's routing endpoint uses the
        // origin/destination pair to choose a segment, so an eastward-only
        // probe can jump to a parallel road or cross street. A CLLocation
        // course is degrees clockwise from true north; fall back to east only
        // when the GPS has no usable course yet.
        let meterDegLat = 1.0 / 111_111.0
        let meterDegLon = 1.0 / (111_111.0 * max(0.000001, cos(coordinate.latitude * .pi / 180)))
        let course = heading.flatMap { value in
            value.isFinite && value >= 0 && value < 360 ? value : nil
        } ?? 90.0
        let normalizedCourse = course
        let headingRadians = normalizedCourse * .pi / 180.0
        let dLat = selfLoopMeters * cos(headingRadians) * meterDegLat
        let dLon = selfLoopMeters * sin(headingRadians) * meterDegLon
        // Use POSIX formatting: a device locale with comma decimal separators
        // would otherwise produce an invalid HERE coordinate query.
        let origin = String(
            format: "%.6f,%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            coordinate.latitude,
            coordinate.longitude
        )
        let dest = String(
            format: "%.6f,%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            coordinate.latitude + dLat,
            coordinate.longitude + dLon
        )

        var components = URLComponents(string: "https://router.hereapi.com/v8/routes")
        components?.queryItems = [
            URLQueryItem(name: "transportMode", value: "car"),
            URLQueryItem(name: "origin", value: origin),
            URLQueryItem(name: "destination", value: dest),
            URLQueryItem(name: "routingMode", value: "fast"),
            // HERE exposes speed limits through route spans. The span
            // boundaries are derived from the returned polyline, so polyline
            // is mandatory; include summary as well for a stable section.
            URLQueryItem(name: "return", value: "summary,polyline,actions"),
            URLQueryItem(name: "units", value: "imperial"),
            // Keep this list to documented span attributes. `segmentRef` is
            // a route response field, not a requestable span attribute on all
            // HERE deployments; an unsupported attribute can make the entire
            // request fail or omit every span.
            URLQueryItem(name: "spans", value: "maxSpeed"),
            URLQueryItem(name: "apiKey", value: creds.accessKeyId)
        ]

        guard let url = components?.url else { return nil }
        let headingText = String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), course)
        DebugLogger.shared.log("HERE REST: requesting route probe \(origin) -> \(dest) heading=\(headingText)")
        var request = URLRequest(url: url, timeoutInterval: 4.0)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Speedio/2.1", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            recordFailure()
            throw error
        }

        guard let http = response as? HTTPURLResponse else {
            recordFailure()
            throw URLError(.badServerResponse)
        }
        DebugLogger.shared.log("HERE REST: HTTP \(http.statusCode) responseBytes=\(data.count)")
        guard (200..<300).contains(http.statusCode) else {
            recordFailure()
            let bodyPreview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
            DebugLogger.shared.log("HERE REST: HTTP \(http.statusCode) body=\(bodyPreview)")
            // 429 specifically: too many requests. Push the failure window
            // longer so the next 30 s of GPS updates skip HERE entirely.
            if http.statusCode == 429 {
                extendFailureCooldown(by: 30)
            }
            return nil
        }

        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            DebugLogger.shared.log("HERE REST: invalid JSON response (bytes=\(data.count))")
            return nil
        }
        guard let routes = payload["routes"] as? [[String: Any]],
              let firstRoute = routes.first,
              let sections = firstRoute["sections"] as? [[String: Any]],
              let firstSection = sections.first else {
            let topLevelKeys = payload.keys.sorted()
            DebugLogger.shared.log("HERE REST: no route section (topLevelKeys=\(topLevelKeys), bytes=\(data.count))")
            return nil
        }

        // Do not discard a valid HERE route solely because a deployment omits
        // or rounds departure metadata differently. The span at offset 0 is
        // already the route's origin span and is the authoritative match for
        // this short probe. Keep the departure check diagnostic-only.
        if !sectionStartMatchesOrigin(firstSection, origin: coordinate) {
            DebugLogger.shared.log("HERE REST: departure metadata is over 120m from GPS fix; parsing origin span anyway")
        }

        guard let speedMph = speedLimitMilesPerHour(in: firstSection) else {
            let spanCount = (firstSection["spans"] as? [[String: Any]])?.count ?? 0
            DebugLogger.shared.log("HERE REST: no usable maxSpeed (spans=\(spanCount), sectionKeys=\(firstSection.keys.sorted()), responseBytes=\(data.count))")
            return nil
        }

        let mph = Int(speedMph.rounded())
        guard mph > 0, mph <= 90 else {
            // 0 == HERE has no posted limit for the segment; >90 is bogus.
            return nil
        }

        recordSuccess(at: nowLoc)

        return SpeedLimitResponse(
            speedLimitMph: mph,
            roadKey: "here-rest-\(mph)",
            providerName: displayName,
            detail: "HERE REST v8 segment speed \(mph) mph"
        )
    }

    /// Verify HERE's snapped route starts near the GPS coordinate used for the
    /// short self-loop. If the response omits departure metadata, retain the
    /// provider's normal behavior and let the span parser decide.
    private func sectionStartMatchesOrigin(_ section: [String: Any], origin: CLLocationCoordinate2D) -> Bool {
        guard let departure = section["departure"] as? [String: Any],
              let place = departure["place"] as? [String: Any],
              let location = place["location"] as? [String: Any] else {
            return true
        }

        let latitude = numericValue(location["lat"] ?? location["latitude"])
        let longitude = numericValue(location["lng"] ?? location["lon"] ?? location["longitude"])
        guard let latitude, let longitude,
              (-90.0...90.0).contains(latitude),
              (-180.0...180.0).contains(longitude) else {
            return false
        }

        let departureLocation = CLLocation(latitude: latitude, longitude: longitude)
        let originLocation = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        return departureLocation.distance(from: originLocation) <= 120
    }

    /// Extract HERE's speed-limit value across the v8 response variants used
    /// by different Routing API deployments. Current Routing API v8 responses
    /// encode `maxSpeed` as meters per second (for example 13.888889 = 50 km/h)
    /// even when the request asks for imperial distances. Older responses put
    /// `maxSpeed`/`speed` in a `speedLimit` object. Unit metadata, when present,
    /// always wins over the m/s default.
    ///
    /// A route can contain more than one span when the short probe crosses an
    /// intersection. The span with the smallest HERE `offset` is the one at
    /// the request origin/current road; blindly taking the first dictionary
    /// entry made an adjacent 25-mph street authoritative.
    private struct SpeedReading {
        let value: Double
        let unit: String?
    }

    /// Pure response parser exposed to the test target so wire-format
    /// regressions can be caught without credentials or a network request.
    internal func speedLimitMilesPerHour(in section: [String: Any]) -> Double? {
        if let spans = section["spans"] as? [[String: Any]], !spans.isEmpty {
            let candidates: [(reading: SpeedReading, offset: Double?, index: Int)] = spans.enumerated().compactMap { index, span in
                guard let reading = speedReading(in: span), reading.value > 0 else { return nil }
                return (reading, numericValue(span["offset"]), index)
            }
            if let selected = candidates.sorted(by: { lhs, rhs in
                switch (lhs.offset, rhs.offset) {
                case let (left?, right?):
                    if left != right { return left < right }
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    break
                }
                return lhs.index < rhs.index
            }).first {
                return milesPerHour(for: selected.reading)
            }
        }

        // Defensive support for deployments that put the value directly on
        // the section rather than returning a spans array.
        guard let reading = speedReading(in: section) else { return nil }
        return milesPerHour(for: reading)
    }

    private func speedReading(in container: [String: Any]) -> SpeedReading? {
        // Current HERE v8 maxSpeed span attribute. A scalar is the normal
        // wire shape; a dictionary is accepted for proxy/legacy responses.
        if let maxSpeed = container["maxSpeed"] as? [String: Any],
           let reading = numericSpeed(in: maxSpeed) {
            return reading
        }
        if let direct = numericValue(container["maxSpeed"]), direct > 0 {
            return SpeedReading(value: direct, unit: unit(in: container))
        }
        // Legacy/deprecated span shape retained for compatibility.
        if let direct = numericValue(container["speedLimit"]), direct > 0 {
            return SpeedReading(value: direct, unit: unit(in: container))
        }
        if let limit = container["speedLimit"] as? [String: Any],
           let reading = numericSpeed(in: limit) {
            return reading
        }
        if let limits = container["speedLimit"] as? [[String: Any]] {
            for limit in limits {
                if let reading = numericSpeed(in: limit) { return reading }
            }
        }
        // Defensive support for flattened span attributes.
        return numericSpeed(in: container)
    }

    private func numericSpeed(in object: [String: Any]) -> SpeedReading? {
        for key in ["maxSpeed", "baseSpeed", "speed", "value"] {
            if let value = numericValue(object[key]), value > 0 {
                return SpeedReading(value: value, unit: unit(in: object))
            }
        }
        return nil
    }

    private func unit(in object: [String: Any]) -> String? {
        for key in ["unit", "speedUnit"] {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func milesPerHour(for reading: SpeedReading) -> Double {
        switch reading.unit?.lowercased().replacingOccurrences(of: " ", with: "") {
        case "mph", "mi/h", "mileperhour", "milesperhour":
            return reading.value
        case "kph", "kmh", "km/h", "kilometerperhour", "kilometersperhour":
            return reading.value * 0.621371
        case "mps", "m/s", "meterpersecond", "meterspersecond":
            return reading.value * 2.23694
        default:
            // HERE Routing API v8's numeric maxSpeed is m/s when no unit
            // metadata is supplied. The units parameter changes distance/time
            // formatting but does not make this wire value MPH. Keep the
            // conversion explicit so 13.888889 becomes 31.1 mph, not 13 mph.
            return reading.value * 2.23694
        }
    }

    private func numericValue(_ value: Any?) -> Double? {
        if let value = value as? Double, value.isFinite { return value }
        if let value = value as? NSNumber {
            let doubleValue = value.doubleValue
            if doubleValue.isFinite { return doubleValue }
        }
        // JSON providers occasionally serialize numeric speed fields as
        // strings. Treat that as a wire-format variation, not a missing limit.
        if let value = value as? String,
           let doubleValue = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)),
           doubleValue.isFinite {
            return doubleValue
        }
        return nil
    }

    private func shouldSkipRequest(at location: CLLocation, forceRefresh: Bool) -> Bool {
        throttleLock.lock()
        defer { throttleLock.unlock() }

        if let last = _lastSuccess,
           !forceRefresh,
           location.distance(from: last) < successMinDistance {
            return true
        }
        if !forceRefresh,
           let lastFailure = _lastFailureAt,
           Date().timeIntervalSince(lastFailure) < failureRetryInterval {
            return true
        }
        return false
    }

    private func recordSuccess(at location: CLLocation) {
        throttleLock.lock()
        _lastSuccess = location
        throttleLock.unlock()
    }

    private func recordFailure() {
        throttleLock.lock()
        _lastFailureAt = Date()
        throttleLock.unlock()
    }

    private func extendFailureCooldown(by interval: TimeInterval) {
        throttleLock.lock()
        _lastFailureAt = Date().addingTimeInterval(interval)
        throttleLock.unlock()
    }
}
