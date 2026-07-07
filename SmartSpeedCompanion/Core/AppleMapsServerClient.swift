// AppleMapsServerClient.swift
// Thin async client for the Apple Maps Server API.
//
// Every endpoint here has a free native equivalent in MapKit / CoreLocation
// (CLGeocoder == /v1/{reverse,}geocode, MKLocalSearch == /v1/search,
//  MKDirections == /v1/directions, MKMapItem.placemark.address ==
//  /v1/place). We use the native lookups as the hot path; this client is
//  called only from:
//
//    1. Backend jobs that enrich recorded drive sessions with a city/state
//       string (one round-trip per journey, batched).
//    2. Future "find fastest detour past a closure" feature that needs an
//       N×M ETA matrix the device can't compute in real time.
//
// Until `AppleMapsServerToken.shared.isConfigured` returns true, every
// public method resolves to empty arrays / nil so the caller doesn't have
// to special-case the unauthenticated state.

import Foundation
import CoreLocation

@MainActor
public final class AppleMapsServerClient {
    public static let shared = AppleMapsServerClient()

    private let baseURL = URL(string: "https://maps-api.apple.com/v1")!

    /// Apple's stated daily limit. Used only for logging — the client never
    /// refuses a request locally; the 429 HTTP status code is the real gate.
    public static let dailyServiceCallLimit = 25_000

    private init() {}
}

extension AppleMapsServerClient {
    /// Apple Maps Server → Directions.
    /// Free equivalent: MKDirections (used everywhere today by DriveViewModel).
    public func directions(origin: CLLocationCoordinate2D, destination: CLLocationCoordinate2D) async -> ServerDirectionsResponse? {
        guard AppleMapsServerToken.shared.isConfigured else { return nil }
        var components = URLComponents(url: baseURL.appendingPathComponent("directions"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "origin", value: "\(origin.latitude),\(origin.longitude)"),
            URLQueryItem(name: "destination", value: "\(destination.latitude),\(destination.longitude)"),
            URLQueryItem(name: "transportType", value: "automobile"),
        ]
        return await fetch(path: components.url?.absoluteString, type: ServerDirectionsResponse.self)
    }

    /// Apple Maps Server → Search (POI).
    /// Free equivalent: MKLocalSearch used by DriveViewModel.searchDestination.
    public func search(query: String, near coordinate: CLLocationCoordinate2D?) async -> [MKMapItemCandidate] {
        guard AppleMapsServerToken.shared.isConfigured else { return [] }
        var components = URLComponents(url: baseURL.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        var q = [URLQueryItem(name: "q", value: query)]
        if let c = coordinate {
            q.append(URLQueryItem(name: "coordinate", value: "\(c.latitude),\(c.longitude)"))
        }
        components.queryItems = q
        struct Resp: Decodable { let results: [MKMapItemCandidate] }
        return (await fetch(path: components.url?.absoluteString, type: Resp.self))?.results ?? []
    }

    /// Apple Maps Server → Reverse Geocode.
    /// Free equivalent: CLGeocoder.reverseGeocodeLocation (used by
    /// DriveViewModel.reverseGeocode). The Server version is for batch
    /// backend enrichment only.
    public func reverseGeocode(_ coord: CLLocationCoordinate2D) async -> ServerAddress? {
        guard AppleMapsServerToken.shared.isConfigured else { return nil }
        var components = URLComponents(url: baseURL.appendingPathComponent("reverseGeocode"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "coordinate", value: "\(coord.latitude),\(coord.longitude)")
        ]
        struct Resp: Decodable { let results: [ServerAddress] }
        return (await fetch(path: components.url?.absoluteString, type: Resp.self))?.results.first
    }

    // MARK: - Internal request plumbing

    private struct ServerError: Decodable { let errorMessage: String? }

    /// Conservative generalized fetch. Reads 401/403/429 and either back-
    /// offs or logs the failure. Apple's retry guidance: respect the
    /// `Retry-After` header (UNIX milliseconds) on 429 responses.
    private func fetch<T: Decodable>(path: String?, type: T.Type, maxRetries: Int = 2) async -> T? {
        guard let urlString = path, let url = URL(string: urlString) else { return nil }
        guard let token = AppleMapsServerToken.shared.token else { return nil }

        var attempt = 0
        var retryDelay: TimeInterval = 1.0

        while attempt <= maxRetries {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 8
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { return nil }

                if http.statusCode == 429 {
                    // Back off: read the server-provided Retry-After if present,
                    // otherwise use exponential jitter.
                    let serverDelay: TimeInterval
                    if let raw = http.value(forHTTPHeaderField: "Retry-After"),
                       let seconds = TimeInterval(raw) {
                        serverDelay = min(seconds, 30)
                    } else {
                        serverDelay = retryDelay
                    }
                    attempt += 1
                    if attempt > maxRetries {
                        DebugLogger.shared.log("[AppleMapsServer] 429 rate-limited, gave up after \(maxRetries) retries.")
                        return nil
                    }
                    try? await Task.sleep(nanoseconds: UInt64(serverDelay * 1_000_000_000))
                    retryDelay *= 2
                    continue
                }

                guard (200..<300).contains(http.statusCode) else {
                    let err = (try? JSONDecoder().decode(ServerError.self, from: data))?.errorMessage
                    DebugLogger.shared.log("[AppleMapsServer] HTTP \(http.statusCode) on \(urlString): \(err ?? "—")")
                    return nil
                }

                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                DebugLogger.shared.log("[AppleMapsServer] request error: \(error.localizedDescription)")
                return nil
            }
        }
        return nil
    }
}

// MARK: - Wire models (Apple Maps Server /v1/* response shapes)
//
// We model only what we currently consume so we don't accidentally double
// down on Apple's stable contract. Each struct's Codable key set is the
// subset of Apple's documented response used by our caller paths.

public struct ServerAddress: Codable, Sendable {
    public let formattedAddress: String?
    public let countryCode: String?       // ISO 3166-1 alpha-2
    public let administrativeArea: String?
    public let locality: String?
    public let postalCode: String?
}

public struct ServerDirectionsResponse: Codable, Sendable {
    public let routes: [ServerRoute]
    public struct ServerRoute: Codable, Sendable {
        public let distanceMeters: Double
        public let expectedTravelTimeSeconds: Double
        public let polyline: String?   // encoded polyline
    }
}

public struct MKMapItemCandidate: Codable, Sendable, Identifiable {
    public let id: String                 // Apple's persistent Place ID
    public let name: String
    public let formattedAddress: String?
    public let coordinate: ServerCoord

    public struct ServerCoord: Codable, Sendable {
        public let latitude: Double
        public let longitude: Double
    }
}
