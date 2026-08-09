// SpeedLimitProvider.swift
// Shared types for the HERE live provider and HERE batch cache.
//
// HERE REST conforms to SpeedLimitProvider for active driving lookups.
// ArcGIS HPMS and Overpass remain available as isolated research/offline tools,
// but are not part of the production driving provider chain.

import Foundation
import CoreLocation

/// Typed speed-limit lookup result, provider-agnostic.
///
/// Returned by any `SpeedLimitProvider` that has data for the queried coordinate.
/// Always normalized to MPH internally so the UI does not have to perform
/// provider-specific unit conversion.
public struct SpeedLimitResponse: Sendable, Equatable, Codable {
    /// Legal speed limit, in miles per hour.
    public let speedLimitMph: Int
    /// Provider-specific stable road identifier. Used as a secondary cache key + for
    /// hysteresis across coordinate changes on the same road segment.
    ///   - HERE REST: provider-specific segment identifier
    ///   - Legacy ArcGIS/Overpass identifiers may appear only in old persisted data
    ///   - Live providers use their own stable road identifiers.
    public let roadKey: String
    /// Human-readable name of the provider that produced this answer.
    public let providerName: String
    /// Descriptive HERE detail for diagnostics and support logs.
    public let detail: String

    public init(speedLimitMph: Int, roadKey: String, providerName: String, detail: String) {
        self.speedLimitMph = speedLimitMph
        self.roadKey = roadKey
        self.providerName = providerName
        self.detail = detail
    }
}

/// Common interface for speed-limit providers used by `SmartSpeedLimitService`.
///
/// Conforming types MUST be `Sendable` (typically `final class` + `@unchecked Sendable`,
/// since most members are stateless singletons). The protocol distinguishes between
/// "I have no record for this point" (return `nil`) and "I tried but the network/parse
/// failed" (throw). The active orchestrator currently accepts HERE REST only.
public protocol SpeedLimitProvider: Sendable {
    /// Short provider name used for logging and `SpeedLimitDataSource` labels.
    var displayName: String { get }

    /// Resolve the speed limit at the given coordinate.
    /// - Returns: `SpeedLimitResponse` if the provider has a record for this area.
    /// - Returns: `nil` if the provider has no coverage for this point.
    /// - Throws: on actual I/O failure, encoding/decoding failure, or rate limiting
    ///   (`URLError.resourceUnavailable` for HTTP 429, generic URLError for network).
    func fetchSpeedLimit(
        at coordinate: CLLocationCoordinate2D,
        heading: Double?,
        forceRefresh: Bool
    ) async throws -> SpeedLimitResponse?
}
