// GeoapifyReverseGeocoder.swift
// Network reverse-geocoding fallback for `RoadGeocoder`.
//
// Endpoint contract (validated):
//   https://api.geoapify.com/v1/geocode/reverse
//     ?lat={lat}
//     &lon={lon}
//     &api_key={key}
//     &format=json
//     &lang=en
//
// Response shape (`features[0].properties`):
//   {
//     "street": "West Frye Road",
//     "address_line1": "West Frye Road, Gilbert, AZ 85233, United States",
//     "city": "Gilbert",
//     "state": "Arizona",
//     "state_code": "AZ",
//     "country": "United States",
//     "postcode": "85233",
//     "suburb": "...",
//     "county": "Maricopa County",
//     "formatted": "...",
//     "result_type": "street",
//     "distance": ...,
//     ...
//   }
//
// Auth: Anonymous Sign-Up gives 2,500 req/day free at 5 req/sec on the
// Free Tier. Credentials live in Keychain via GeoapifyCredentialStore.
// If credentials are missing, this provider returns nil and the chain
// falls through (priced as "No Data" for the road name).
//
// Throttle state is guarded by an NSLock because the provider is `final`
// non-actor — Swift concurrency allows concurrent awaiters and mutable
// lastSuccess/lastFailureAt would otherwise race.

import Foundation
import CoreLocation

public final class GeoapifyReverseGeocoder: @unchecked Sendable {
    public let displayName: String = "Geoapify"

    private let throttleLock = NSLock()
    private var _lastSuccess: CLLocation?
    private var _lastFailureAt: Date?
    private let successMinDistance: CLLocationDistance = 100
    private let failureRetryInterval: TimeInterval = 10

    public init() {}

    /// Mirror of `RoadIdentification`-shaped data extracted from a single
    /// Geoapify feature. The caller (RoadGeocoder) maps these onto a real
    /// `RoadIdentification`, so we keep this struct narrow.
    public struct GeoapifyResponse: Sendable, Equatable {
        public let roadName: String?
        public let city: String?
        /// 2-letter ISO code (e.g. "AZ") if Geoapify supplies it; otherwise
        /// the full state name ("Arizona"). Mirrors CLGeocoder preference.
        public let state: String?
        public let country: String?

        public init(
            roadName: String?,
            city: String?,
            state: String?,
            country: String?
        ) {
            self.roadName = roadName
            self.city = city
            self.state = state
            self.country = country
        }
    }

    /// Returns a `GeoapifyResponse` for the closest mappable feature at
    /// `coord`, or nil when:
    ///   - the API key is missing from Keychain
    ///   - a recent successful call is within `successMinDistance` of `coord`
    ///   - a recent failure happened within `failureRetryInterval`
    ///   - the HTTP call throws or returns non-2xx (429 gets a 30 s cooldown)
    ///   - the response body is undeserializable / has zero features
    public func reverse(coordinate coord: CLLocationCoordinate2D) async -> GeoapifyResponse? {
        let nowLoc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)

        // Keep NSLock access inside synchronous helpers. Swift 6 rejects
        // direct lock/unlock calls from this async network method.
        guard !shouldSkipRequest(at: nowLoc) else { return nil }

        // Credentials gate. No creds == user hasn't onboarded yet, so we
        // silently fall through instead of crashing the chain on auth errors.
        guard let apiKey = GeoapifyCredentialStore.shared.loadApiKey() else {
            DebugLogger.shared.log("Geoapify: API key missing in Keychain; falling through")
            return nil
        }

        var components = URLComponents(string: "https://api.geoapify.com/v1/geocode/reverse")
        components?.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.6f", coord.latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.6f", coord.longitude)),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "lang", value: "en"),
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
            return nil
        }

        guard let http = response as? HTTPURLResponse else {
            recordFailure()
            return nil
        }
        guard (200..<300).contains(http.statusCode) else {
            recordFailure()
            let bodyPreview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
            DebugLogger.shared.log("Geoapify: HTTP \(http.statusCode) body=\(bodyPreview)")
            // 429 specifically: too many requests. Push the failure window
            // longer so the next 30 s of GPS updates skip Geoapify entirely.
            if http.statusCode == 429 {
                extendFailureCooldown(by: 30)
            }
            return nil
        }

        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = payload["features"] as? [[String: Any]],
              let first = features.first,
              let props = first["properties"] as? [String: Any] else {
            return nil
        }

        let street = nonEmpty(props["street"])
        let state = nonEmpty(props["state_code"]) ?? nonEmpty(props["state"])
        let city = nonEmpty(props["city"])
            ?? nonEmpty(props["town"])
            ?? nonEmpty(props["village"])
            ?? nonEmpty(props["suburb"])
        let country = nonEmpty(props["country"])

        // Resolve the road name in this priority:
        //   1. properties.street (highest confidence)
        //   2. address_line1 leading segment ("West Frye Road, ... -> "West Frye Road")
        //   3. formatted leading segment (last resort)
        let roadName = street
            ?? leadingSegment(nonEmpty(props["address_line1"]))
            ?? leadingSegment(nonEmpty(props["formatted"]))

        recordSuccess(at: nowLoc)

        return GeoapifyResponse(
            roadName: roadName,
            city: city,
            state: state,
            country: country
        )
    }

    private func shouldSkipRequest(at location: CLLocation) -> Bool {
        throttleLock.lock()
        defer { throttleLock.unlock() }

        if let last = _lastSuccess,
           location.distance(from: last) < successMinDistance {
            return true
        }
        if let lastFailure = _lastFailureAt,
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

    /// Trimmed non-blank string. Treats "" as nil so callers can chain `??`.
    private func nonEmpty(_ raw: Any?) -> String? {
        guard let s = raw as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Take the substring before the first comma. Works for both
    /// address_line1 ("West Frye Road, Gilbert, AZ ...") and
    /// formatted ("West Frye Road, Gilbert, AZ 85233, ...").
    private func leadingSegment(_ s: String?) -> String? {
        guard let s, let first = s.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true).first else {
            return nil
        }
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
