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
// "West Frye Road". Results are always tied to the coordinate that produced
// them; a nearby intersection must not reuse a road name from an adjacent
// 50 m grid cell.

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

    /// Small de-duplication grid (~25m at Phoenix latitudes). A larger
    /// bucket can straddle an intersection and incorrectly reuse the name of
    /// a nearby cross street.
    private let gridPrecision: Double = 0.00025
    /// 24h TTL matches the on-disk SpeedLimitResponseCache diskTtl.
    private let ttlSeconds: TimeInterval = 24 * 60 * 60
    /// A grid cell is a de-duplication bucket, not proof that every point in
    /// it is on the same road. Keep a cached answer only when the new fix is
    /// genuinely near the coordinate that produced the answer.
    private let maxCachedCoordinateDistance: CLLocationDistance = 18

    private var memory: [String: RoadIdentification] = [:]
    /// In-flight de-dup: grid key -> Task awaiting any backend's response.
    private var inflight: [String: Task<RoadIdentification?, Never>] = [:]
    /// Request generations prevent an older in-flight geocode from writing its
    /// road name back after a newer coordinate has forced an independent lookup.
    private var inflightGeneration: [String: UInt64] = [:]
    private var nextGeneration: UInt64 = 0

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
    /// Set `forceRefresh` when a caller must validate the road at the latest
    /// GPS fix rather than reusing a nearby cached answer (for example, after
    /// an asynchronous request crosses an intersection).
    public func resolveRoadContext(
        at coord: CLLocationCoordinate2D,
        forceRefresh: Bool = false
    ) async -> RoadIdentification? {
        let key = gridKey(for: coord)
        if forceRefresh {
            memory.removeValue(forKey: key)
        }
        if !forceRefresh, let cached = memory[key] {
            let cachedLocation = CLLocation(latitude: cached.coord.latitude, longitude: cached.coord.longitude)
            let requestedLocation = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            if Date().timeIntervalSince(cached.resolvedAt) < ttlSeconds,
               cachedLocation.distance(from: requestedLocation) <= maxCachedCoordinateDistance {
                return cached
            }
            // Do not let a stale or cross-street answer survive merely because
            // both fixes round into the same spatial bucket.
            memory.removeValue(forKey: key)
        }
        // De-dup: if another caller is already geocoding this cell, await it,
        // but never hand its answer to a coordinate that is too far from the
        // fix that produced that answer. A single grid cell can straddle an
        // intersection (the Riggs/Cedarcest failure mode).
        if let pending = inflight[key] {
            let result = await pending.value
            if !forceRefresh,
               let result,
               Date().timeIntervalSince(result.resolvedAt) < ttlSeconds,
               CLLocation(latitude: result.coord.latitude, longitude: result.coord.longitude)
                    .distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude)) <= maxCachedCoordinateDistance {
                return result
            }

            // The in-flight result belongs to another nearby fix. Invalidate
            // its write token before resolving this coordinate independently,
            // so the older task cannot overwrite the newer road name later.
            nextGeneration &+= 1
            let generation = nextGeneration
            inflightGeneration[key] = generation
            let replacement = await Self.geocode(coordinate: coord)
            guard inflightGeneration[key] == generation else { return replacement }
            inflightGeneration.removeValue(forKey: key)
            inflight.removeValue(forKey: key)
            if let replacement {
                memory[key] = replacement
            }
            return replacement
        }

        nextGeneration &+= 1
        let generation = nextGeneration
        let task = Task<RoadIdentification?, Never> { [coord] in
            await Self.geocode(coordinate: coord)
        }
        inflight[key] = task
        inflightGeneration[key] = generation
        let result = await task.value
        // Only the newest request for this key may publish or clear the entry.
        guard inflightGeneration[key] == generation else { return result }
        inflightGeneration.removeValue(forKey: key)
        inflight.removeValue(forKey: key)
        if let result {
            memory[key] = result
        }
        return result
    }

    /// Drop everything (e.g. when the user ends a drive session).
    public func clearCache() {
        memory.removeAll()
        // Cancel and discard all in-flight ownership records so an old
        // completion cannot leave a stale task reachable or publish into a
        // later drive session.
        for task in inflight.values {
            task.cancel()
        }
        inflight.removeAll()
        inflightGeneration.removeAll()
        nextGeneration &+= 1
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
