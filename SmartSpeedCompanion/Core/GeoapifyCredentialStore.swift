// GeoapifyCredentialStore.swift
// Loads the Geoapify API key from iOS Keychain.
//
// Service:   com.speedsense.geoapify
// Account:   api_key
//
// GeoapifyReverseGeocoder returns nil if no key is loaded so the
// `RoadGeocoder` chain silently falls back to spatial-only scoring
// instead of crashing on auth errors. Users can paste their free-tier
// key (https://myprojects.geoapify.com) into the Developer tab and the
// network fallback lights up immediately without re-launching.
//
// Anonymous Sign-Up gives 2,500 req/day free at 5 req/sec — enough to
// cover a typical drive's worth of geocode misses where CLGeocoder's
// on-device index is stale (flyovers, new subdivisions, rural roads).

import Foundation

public final class GeoapifyCredentialStore: Sendable {
    public static let shared = GeoapifyCredentialStore()

    // Constants only — safe to share across actor isolation. `nonisolated`
    // (not `nonisolated(unsafe)`) is the correct marker: the underlying
    // `KeychainHelper.standard` is a Sendable class (no mutable state),
    // so there is nothing to escape from.
    nonisolated private let keychain: KeychainHelper
    nonisolated private let serviceName = "com.speedsense.geoapify"
    nonisolated private let apiKeyAccount = "api_key"

    private init() {
        self.keychain = KeychainHelper.standard
    }

    /// Returns nil if the API key is missing or unparseable.
    public func loadApiKey() -> String? {
        guard let data = keychain.read(service: serviceName, account: apiKeyAccount),
              let key = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            return nil
        }
        return key
    }

    /// Save (or overwrite) the API key. No-op if the input trims to empty.
    public func saveApiKey(_ apiKey: String) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8) else { return }
        keychain.save(data, service: serviceName, account: apiKeyAccount)
        DebugLogger.shared.log("Geoapify API key saved to Keychain")
    }

    /// Wipe the API key. Used by account deletion / debug reset.
    public func clearApiKey() {
        keychain.delete(service: serviceName, account: apiKeyAccount)
        DebugLogger.shared.log("Geoapify API key cleared from Keychain")
    }

    /// True iff a non-empty API key is loaded. Used by `RoadGeocoder` to
    /// skip the network fallback entirely when the user has not opted in.
    public func hasApiKey() -> Bool {
        return loadApiKey() != nil
    }
}
