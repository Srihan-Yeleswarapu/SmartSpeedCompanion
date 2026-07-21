// SpeedLimitDataSource.swift
// Typed enum that replaces the stringly-typed "DB", "DB (Recovered)", "No Data"
// labels previously hard-coded into SmartSpeedLimitService.
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
    /// Live data from the ArcGIS HPMS FeatureServer (layer 48 — SpeedLimit_2024).
    case liveArcGIS = "Live (ArcGIS)"
    /// Live data from the OpenStreetMap Overpass API (queries the OSM `maxspeed` tag).
    case liveOverpass = "Live (Overpass)"
    /// Local SQLite fallback (AZ geodatabase from the bundled .sqlite / .geodatabase file).
    case localDB = "DB"
    /// Local SQLite fallback with the expanded-search path (60m radius instead of 20m).
    case localDBRecovered = "DB (Recovered)"
    /// No recent answer from any provider. UI should display a friendly "searching" message.
    case noData = "No Data"
}
