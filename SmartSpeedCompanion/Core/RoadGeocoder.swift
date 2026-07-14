// RoadGeocoder.swift
// Standalone service that turns a (lat, lon) into a road name + city, cached per
// 50m grid cell so we don't rate-limit CLGeocoder on every location update.
// Consumed by SpeedEngine.processLocation(_:) which forwards the road name
// into SmartSpeedLimitService.updateSpeedLimit(at:heading:currentSpeedMph:roadName:).
//
// Two backends, picked in order by availability:
//   1. CLGeocoder.reverseGeocodeLocation (Apple, free, on-device index hits first)
//   2. Geoapify /v1/geocode/reverse (network fallback, free tier = 2.5k req/day);
//      silently skipped when GeoapifyCredentialStore.hasApiKey() == false so
//      the chain degrades to spatial-only scoring instead of crashing.
//
// Either returns placemark.thoroughfare = "W Frye Rd" / properties.street =
// "West Frye Road" which `RoadNameMatcher.normalize(_:)` aliases to "FRYE RD"
// so the SQLite lookup bites.

import Foundation
import CoreLocation

public struct RoadIdentification: Sendable {
    public let roadName: String?    // e.g. "W Frye Rd"
    public let roadRef: String?     // e.g. "07" city prefix if discoverable
    public let city: String?        // e.g. "Chandler"
    public let state: String?       // e.g. "AZ"
    public let resolvedAt: Date
    public let coord: CLLocationCoordinate2D

    public init(
        roadName: String?,
        roadRef: String?,
        city: String?,
        state: String?,
        resolvedAt: Date = Date(),
        coord: CLLocationCoordinate2D
    ) {
        self.roadName = roadName
        self.roadRef = roadRef
        self.city = city
        self.state = state
        self.resolvedAt = resolvedAt
        self.coord = coord
    }
}

/// Singleton actor that owns the 50m-grid cache + a small in-flight de-dup map
/// so a cluster of concurrent resolveRoadContext(at:) calls coalesce into one
/// CLGeocoder hit.
public actor RoadGeocoder {
    public static let shared = RoadGeocoder()

    /// 50m grid precision (~0.0005° at AZ latitudes).
    private let gridPrecision: Double = 0.0005
    /// 24h TTL matches the on-disk SpeedLimitResponseCache diskTtl.
    private let ttlSeconds: TimeInterval = 24 * 60 * 60

    private var memory: [String: RoadIdentification] = [:]
    /// In-flight de-dup: grid key -> Task awaiting any backend's response.
    private var inflight: [String: Task<RoadIdentification?, Never>] = [:]

    /// Network fallback. Singleton so its NSLock-guarded throttle state
    /// survives across `resolveRoadContext` calls instead of being reset
    /// on every call (which would burn the Geoapify free tier in seconds).
    private static let geoapify = GeoapifyReverseGeocoder()

    private init() {}

    public func gridKey(for coord: CLLocationCoordinate2D) -> String {
        let latKey = (coord.latitude / gridPrecision).rounded() * gridPrecision
        let lonKey = (coord.longitude / gridPrecision).rounded() * gridPrecision
        return String(format: "g:%.4f,%.4f", latKey, lonKey)
    }

    /// Resolve the road the user is on at `coord`. Returns a cached entry if
    /// fresh (within 24h); otherwise falls through to CLGeocoder. Returns nil
    /// if geocode fails -- the caller should degrade to spatial-only lookup.
    public func resolveRoadContext(at coord: CLLocationCoordinate2D) async -> RoadIdentification? {
        let key = gridKey(for: coord)
        if let cached = memory[key] {
            if Date().timeIntervalSince(cached.resolvedAt) < ttlSeconds {
                return cached
            }
            memory.removeValue(forKey: key)
        }
        // De-dup: if another caller is already geocoding this cell, await them.
        if let pending = inflight[key] {
            return await pending.value
        }
        let task = Task<RoadIdentification?, Never> { [coord] in
            await Self.geocode(coordinate: coord)
        }
        inflight[key] = task
        let result = await task.value
        inflight.removeValue(forKey: key)
        if let result = result {
            memory[key] = result
        }
        return result
    }

    /// Drop everything (e.g. when the user ends a drive session).
    public func clearCache() {
        memory.removeAll()
    }

    private static func geocode(coordinate coord: CLLocationCoordinate2D) async -> RoadIdentification? {
        // Tier 1: CLGeocoder (Apple, free, on-device index). Skips the
        // network entirely when the user is in a well-indexed region.
        if let ident = await clGeocoderReverse(coordinate: coord) {
            return ident
        }
        // Tier 2: Geoapify (network fallback). 2.5k req/day free, opted-in
        // only when the user has pasted their key into the Developer tab.
        return await geoapifyReverseGeocode(coordinate: coord)
    }

    private static func clGeocoderReverse(
        coordinate coord: CLLocationCoordinate2D
    ) async -> RoadIdentification? {
        let location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        if let p = try? await CLGeocoder().reverseGeocodeLocation(location).first {
            return RoadIdentification(
                roadName: p.thoroughfare,
                roadRef: p.subLocality,
                city: p.locality,
                state: p.administrativeArea,
                coord: coord
            )
        }
        return nil
    }

    private static func geoapifyReverseGeocode(
        coordinate coord: CLLocationCoordinate2D
    ) async -> RoadIdentification? {
        guard let resp = await geoapify.reverse(coordinate: coord) else { return nil }
        return RoadIdentification(
            roadName: resp.roadName,
            roadRef: nil,
            city: resp.city,
            state: resp.state,
            coord: coord
        )
    }
}
