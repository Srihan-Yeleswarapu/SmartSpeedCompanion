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
//     &return=summary
//     &units=imperial
//     &spans=names,maxSpeed
//     &apiKey={access_key_id}
//
// Speed limits are span attributes, not `return` values. Without the `spans`
// query item HERE returns a valid route with no speed-limit field; the old
// `return=summary,speedLimit` request therefore made every live lookup
// resolve to No Data. Current HERE v8 exposes the limit as `maxSpeed` and the
// explicit imperial unit makes the returned value directly usable as MPH.
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

public final class HERERestSpeedLimitProvider: SpeedLimitProvider, @unchecked Sendable {
    public let displayName: String = "HERE REST"

    private let throttleLock = NSLock()
    private var _lastSuccess: CLLocation?
    private var _lastFailureAt: Date?
    private let successMinDistance: CLLocationDistance = 100
    private let failureRetryInterval: TimeInterval = 10
    // ~35 m probe. 5 m is too tight — HERE sometimes returned the speed of an
    // adjacent street segment. The probe follows the vehicle course whenever
    // one is available, so it samples the road ahead instead of an arbitrary
    // eastward segment at intersections.
    private let selfLoopMeters: Double = 35

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

        // Credentials gate. No creds == the user hasn't onboarded yet, so we
        // silently fall through instead of crashing the chain on auth errors.
        guard let creds = HERECredentialStore.shared.loadCredentials() else {
            DebugLogger.shared.log("HERE REST: credentials missing; active HERE source unavailable")
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
        let origin = String(format: "%.6f,%.6f", coordinate.latitude, coordinate.longitude)
        let dest = String(format: "%.6f,%.6f",
                          coordinate.latitude + dLat, coordinate.longitude + dLon)

        var components = URLComponents(string: "https://router.hereapi.com/v8/routes")
        components?.queryItems = [
            URLQueryItem(name: "transportMode", value: "car"),
            URLQueryItem(name: "origin", value: origin),
            URLQueryItem(name: "destination", value: dest),
            URLQueryItem(name: "routingMode", value: "fast"),
            // HERE exposes speed limits through the `spans` parameter. They
            // are not valid members of the `return` list. `maxSpeed` is the
            // current v8 attribute; the parser retains a legacy speedLimit
            // fallback for older API deployments.
            URLQueryItem(name: "return", value: "summary"),
            URLQueryItem(name: "units", value: "imperial"),
            URLQueryItem(name: "spans", value: "names,maxSpeed"),
            URLQueryItem(name: "apiKey", value: creds.accessKeyId)
        ]

        guard let url = components?.url else { return nil }
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

        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let routes = payload["routes"] as? [[String: Any]],
              let firstRoute = routes.first,
              let sections = firstRoute["sections"] as? [[String: Any]],
              let firstSection = sections.first else {
            DebugLogger.shared.log("HERE REST: response contained no usable route section")
            return nil
        }

        // Reject a route that HERE snapped away from the requested GPS fix.
        // Without this check, the first/lowest-offset span can legitimately be
        // a nearby 25-mph side street even though the driver is on the arterial.
        guard sectionStartMatchesOrigin(firstSection, origin: coordinate) else {
            DebugLogger.shared.log("HERE REST: rejected route whose departure is not near the GPS fix")
            return nil
        }

        guard let speedMph = speedLimitMilesPerHour(in: firstSection) else {
            DebugLogger.shared.log("HERE REST: response contained no usable speed-limit field")
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
    /// by different Routing API deployments. Current responses put `maxSpeed`
    /// on a requested route span; older responses put `maxSpeed`/`speed` in a
    /// `speedLimit` object. Because the request explicitly asks for imperial
    /// units, a unit-less current value is already MPH.
    ///
    /// A route can contain more than one span when the short probe crosses an
    /// intersection. The span with the smallest HERE `offset` is the one at
    /// the request origin/current road; blindly taking the first dictionary
    /// entry made an adjacent 25-mph street authoritative.
    private struct SpeedReading {
        let value: Double
        let unit: String?
    }

    private func speedLimitMilesPerHour(in section: [String: Any]) -> Double? {
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
        // Current HERE v8 maxSpeed span attribute.
        if let direct = numericValue(container["maxSpeed"]), direct > 0 {
            return SpeedReading(value: direct, unit: unit(in: container))
        }
        if let maxSpeed = container["maxSpeed"] as? [String: Any],
           let reading = numericSpeed(in: maxSpeed) {
            return reading
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
            // The request includes units=imperial, so current unit-less
            // maxSpeed values are MPH. This also keeps older numeric responses
            // usable when HERE omits the unit metadata.
            return reading.value
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
