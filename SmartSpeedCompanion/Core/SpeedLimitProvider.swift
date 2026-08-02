// SpeedLimitProvider.swift
// Shared types for all active speed-limit providers (live network + HERE batch cache).
//
// HERE REST, ArcGIS HPMS, and Overpass conform to SpeedLimitProvider.

import Foundation
import CoreLocation

/// Typed speed-limit lookup result, provider-agnostic.
///
/// Returned by any `SpeedLimitProvider` that has data for the queried coordinate.
/// Always normalized to MPH internally so the UI doesn't have to think about units
/// (Overpass can return km/h on European data; we convert before emitting).
public struct SpeedLimitResponse: Sendable, Equatable, Codable {
    /// Legal speed limit, in miles per hour.
    public let speedLimitMph: Int
    /// Provider-specific stable road identifier. Used as a secondary cache key + for
    /// hysteresis across coordinate changes on the same road segment.
    ///   - ArcGIS HPMS: "SR<SRNumber>-<Direction>" (e.g. "SR010-NB")
    ///   - Overpass: "way<OSM_WAY_ID>" (e.g. "way123456789")
    ///   - Live providers use their own stable road identifiers.
    public let roadKey: String
    /// Human-readable name of the provider that produced this answer.
    public let providerName: String
    /// Descriptive detail (e.g. "I-10 EB; Regulatory (White)" / "OSM way 123456789 / residential").
    public let detail: String

    public init(speedLimitMph: Int, roadKey: String, providerName: String, detail: String) {
        self.speedLimitMph = speedLimitMph
        self.roadKey = roadKey
        self.providerName = providerName
        self.detail = detail
    }
}

/// Common interface for any speed-limit provider used by `SmartSpeedLimitService`.
///
/// Conforming types MUST be `Sendable` (typically `final class` + `@unchecked Sendable`,
/// since most members are stateless singletons). The protocol distinguishes between
/// "I have no record for this point" (return `nil`) and "I tried but the network/parse
/// failed" (throw). The orchestrator relies on this distinction to decide whether to
/// walk the active live-provider chain or return a miss when no provider has data.
public protocol SpeedLimitProvider: Sendable {
    /// Short provider name used for logging and `SpeedLimitDataSource` labels.
    var displayName: String { get }

    /// Resolve the speed limit at the given coordinate.
    /// - Returns: `SpeedLimitResponse` if the provider has a record for this area.
    /// - Returns: `nil` if the provider genuinely has no coverage for this point
    ///   (e.g. ArcGIS HPMS only covers FHWA sample-panel sections).
    /// - Throws: on actual I/O failure, encoding/decoding failure, or rate limiting
    ///   (`URLError.resourceUnavailable` for HTTP 429, generic URLError for network).
    func fetchSpeedLimit(
        at coordinate: CLLocationCoordinate2D,
        heading: Double?
    ) async throws -> SpeedLimitResponse?
}
