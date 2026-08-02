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
//     &return=summary,speedLimit
//     &apiKey={access_key_id}
//
// Response: `routes[].sections[].speedLimit` object with `speed` field in m/s.
//
// Auth: HERE Freemium tier — 250k requests/month free PERMANENTLY (NOT a
// 90-day trial). Credentials live in Keychain via HERECredentialStore.
// If credentials are missing, this provider returns nil and the orchestrator's
// chain falls through to ArcGIS/Overpass/SQLite unchanged.
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
        heading: Double?
    ) async throws -> SpeedLimitResponse? {
        // Throttle gate (locked).
        let nowLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        throttleLock.lock()
        if let last = _lastSuccess {
            let dist = nowLoc.distance(from: last)
            throttleLock.unlock()
            if dist < successMinDistance { return nil }
        } else {
            throttleLock.unlock()
        }
        throttleLock.lock()
        if let lastFail = _lastFailureAt,
           Date().timeIntervalSince(lastFail) < failureRetryInterval {
            throttleLock.unlock()
            return nil
        }
        throttleLock.unlock()

        // Credentials gate. No creds == the user hasn't onboarded yet, so we
        // silently fall through instead of crashing the chain on auth errors.
        guard let creds = HERECredentialStore.shared.loadCredentials() else {
            DebugLogger.shared.log("HERE REST: credentials missing in Keychain; falling through")
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
            URLQueryItem(name: "return", value: "summary,speedLimit"),
            URLQueryItem(name: "apiKey", value: creds.accessKeyId)
        ]

        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 4.0)
        request.httpMethod = "GET"
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
                throttleLock.lock()
                _lastFailureAt = Date().addingTimeInterval(30)
                throttleLock.unlock()
            }
            return nil
        }

        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let routes = payload["routes"] as? [[String: Any]],
              let firstRoute = routes.first,
              let sections = firstRoute["sections"] as? [[String: Any]],
              let firstSection = sections.first,
              let speedLimitObj = firstSection["speedLimit"] as? [String: Any],
              let speedValue = speedLimitObj["speed"] as? Double else {
            return nil
        }

        // HERE returns speed in m/s. Convert to mph.
        let mph = Int((speedValue * 2.23694).rounded())
        guard mph > 0, mph <= 90 else {
            // 0 == HERE has no posted limit for the segment; >90 is bogus.
            return nil
        }

        throttleLock.lock()
        _lastSuccess = nowLoc
        throttleLock.unlock()

        return SpeedLimitResponse(
            speedLimitMph: mph,
            roadKey: "here-rest-\(Int(speedValue))",
            providerName: displayName,
            detail: "HERE REST v8 segment speed \(mph) mph"
        )
    }

    private func recordFailure() {
        throttleLock.lock()
        _lastFailureAt = Date()
        throttleLock.unlock()
    }
}
