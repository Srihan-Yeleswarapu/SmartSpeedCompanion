// AppleMapsServerToken.swift
// Wrapper for the optional Apple Maps Server API token.
//
// The token unlocks server-side endpoints:
//   - /v1/geocode, /v1/reverseGeocode
//   - /v1/search, /v1/searchAutocomplete
//   - /v1/directions, /v1/matrix
//   - /v1/place
//
// All of these have FREE on-device equivalents (CLGeocoder, MKLocalSearch,
// MKDirections, MKMapItem.openInMaps) and we use those by default.
//
// The Server API adds value only when:
//   - Batch / server-side enrichment is needed (e.g. reverse-geocoding
//     every recorded drive session in the cloud)
//   - Persistent Place IDs need to be resolved server-side
//   - Multi-origin / multi-destination ETA matrix is needed (e.g. finding
//     "fastest detour past a closed road")
//
// Until then, `AppleMapsServerToken.shared.token` returns nil and the
// AppleMapsServerClient methods become no-ops. The user pastes the token
// from developer.apple.com once and every server-side call lights up.
//
// To issue a token (paste into Settings → Apple Maps Server API):
//   1. developer.apple.com/account (must be in the $99/yr Developer Program)
//   2. Certificates, Identifiers & Profiles → Identifiers → "+"
//   3. Maps IDs → Continue → pick a description + bundle ID prefix
//      (e.g. com.speedsense.app)
//   4. Confirm. Then under Maps → Server API, click "Create Token".
//   5. Copy the token string (starts with "ey…"). Apple regenerates tokens
//      at will — keep the Keychain copy fresh.

import Foundation

@MainActor
public final class AppleMapsServerToken {
    public static let shared = AppleMapsServerToken()

    // Match KeychainHelper.save(_:service:account:) / read(service:account:)
    // / delete(service:account:) — service first, account second.
    private static let keychainService  = "com.speedsense.app.maps"
    private static let keychainAccount  = "apple-maps-server-api-token"

    /// The bearer token. nil when the user hasn't pasted one yet (the
    /// expected default for v2.1.x builds).
    public var token: String? {
        guard let data = KeychainHelper.standard.read(
            service: Self.keychainService,
            account: Self.keychainAccount
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// True iff a valid token-shaped string is loaded. Used by
    /// `AppleMapsServerClient` to gate its endpoints so missing-token
    /// builds never make a doomed HTTP request. Apple's tokens start with
    /// "ey" (JWT), and are usually 200+ chars long.
    public var isConfigured: Bool {
        guard let t = token else { return false }
        return t.count > 16 && t.hasPrefix("ey")
    }

    /// Persists `token` in Keychain. Throws if the UTF-8 conversion fails
    /// — actual Keychain OSStatus failures are silent (matching the rest
    /// of the codebase's KeychainHelper API).
    public func saveToken(_ token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw NSError(
                domain: "AppleMapsServerToken",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Token is not valid UTF-8."]
            )
        }
        KeychainHelper.standard.save(
            data,
            service: Self.keychainService,
            account: Self.keychainAccount
        )
    }

    public func clearToken() {
        KeychainHelper.standard.delete(
            service: Self.keychainService,
            account: Self.keychainAccount
        )
    }

    private init() {}
}
