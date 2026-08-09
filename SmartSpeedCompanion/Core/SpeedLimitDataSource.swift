// SpeedLimitDataSource.swift
// Typed enum that replaces the stringly-typed source labels previously hard-coded
// into SmartSpeedLimitService. The legacy DB cases remain Codable-compatible but
// are retired and are never produced by the active provider pipeline.
//
// Why typed (not String)?
//   - Catches typos at compile time (you can't write `.lvieArcGIS` by mistake).
//   - The UI can either display `.rawValue` directly, or map each case to a
//     localized strings file later. Today the UI just reads `rawValue`.
//   - Existing string keys ("DB", "DB (Recovered)", "No Data") are preserved
//     so the DeveloperTabView / DebugLogger strings don't change.

import Foundation

public enum SpeedLimitDataSource: String, Equatable, Codable, Sendable, CaseIterable {
    /// Data from the HERE Route Matching API batch cache (stored locally from
    /// initial setup grid + just-in-time geofence fetches).
    case batchCache = "Batch (HERE)"
    /// Live data from HERE REST v8 `/v8/routes` with `return=speedLimit`. Highest
    /// accuracy on signed arterials; uses user-supplied HERE Platform creds from
    /// Keychain (HERECredentialStore). 250k requests/month FREE PERMANENTLY.
    case liveHERE = "Live (HERE)"
    /// Legacy ArcGIS value retained only so older persisted state can decode.
    /// It is not produced by the active driving pipeline.
    case liveArcGIS = "Live (ArcGIS)"
    /// Legacy OpenStreetMap value retained only so older persisted state can decode.
    /// It is not produced by the active driving pipeline.
    case liveOverpass = "Live (Overpass)"
    /// Legacy local-DB source retained for decoding older persisted state.
    /// Retired — the app now uses only live network providers.
    case localDB = "DB"
    /// Legacy expanded-search local-DB source retained for compatibility.
    /// Retired — the app now uses only live network providers.
    case localDBRecovered = "DB (Recovered)"
    /// No recent answer from any provider. UI should display a friendly "searching" message.
    case noData = "No Data"
}
