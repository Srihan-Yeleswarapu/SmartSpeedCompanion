// HERECredentialStore.swift
// Loads HERE Platform API Key from either:
//   1. iOS Keychain (user-provided override, e.g. dev/test keys)
//   2. Bundled HERE-Config.plist (single app-wide key shipped with the IPA)
//
// The plist fallback means every user gets the same bundled key with no
// per-user setup. The Keychain path exists for debugging / overriding.
//
// Bundled HERE-Config.plist format (single API Key — recommended):
//   <?xml version="1.0" encoding="UTF-8"?>
//   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" ...>
//   <plist version="1.0">
//   <dict>
//       <key>api_key</key>
//       <string>YOUR_HERE_API_KEY</string>
//   </dict>
//   </plist>
//
// Legacy format (access_key_id + access_key_secret) is also accepted for
// backward compatibility with the OAuth 2.0 credential pair.
//
// The REAL HERE-Config.plist is gitignored (in .gitignore). A template
// HERE-Config.plist.example lives in the repo for reference. CI injects
// the real key via GitHub Actions secrets at build time.

import Foundation

public final class HERECredentialStore: Sendable {
    public static let shared = HERECredentialStore()

    // Constants only — safe to share across actor isolation. `nonisolated`
    // (not `nonisolated(unsafe)`) is the correct marker: the underlying
    // `KeychainHelper.standard` is a Sendable class (no mutable state),
    // so there is nothing to escape from.
    nonisolated private let keychain: KeychainHelper
    nonisolated private let serviceName = "com.speedsense.here"
    nonisolated private let accessKeyIdAccount = "access_key_id"
    nonisolated private let accessKeySecretAccount = "access_key_secret"
    nonisolated private let apiKeyAccount = "api_key"

    private init() {
        self.keychain = KeychainHelper.standard
    }

    public struct Credentials: Sendable {
        public let accessKeyId: String
        public let accessKeySecret: String
    }

    /// Returns credentials from the Keychain (if present) OR from the bundled
    /// HERE-Config.plist. Returns nil if neither source has valid keys.
    public func loadCredentials() -> Credentials? {
        // 1. Keychain override (development / testing).
        if let fromKeychain = loadFromKeychain() {
            return fromKeychain
        }
        // 2. Bundled plist (production — single app-wide key).
        return loadFromBundledPlist()
    }

    /// Try loading from the iOS Keychain.
    private func loadFromKeychain() -> Credentials? {
        guard let idData = keychain.read(service: serviceName, account: accessKeyIdAccount),
              let secretData = keychain.read(service: serviceName, account: accessKeySecretAccount),
              let id = String(data: idData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let secret = String(data: secretData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty,
              !secret.isEmpty else {
            return nil
        }
        return Credentials(accessKeyId: id, accessKeySecret: secret)
    }

    /// Fallback: read credentials from the bundled HERE-Config.plist.
    ///
    /// Supports two formats:
    ///   1. Single `api_key` key (recommended — simple HERE API Key token)
    ///   2. Paired `access_key_id` + `access_key_secret` (legacy OAuth 2.0)
    ///
    /// In both cases the value is placed into the `accessKeyId` field so the
    /// provider can use it as the `apiKey=` query parameter.
    private func loadFromBundledPlist() -> Credentials? {
        guard let url = Bundle.main.url(forResource: "HERE-Config", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: String] else {
            return nil
        }

        // Format 1: Single API Key (recommended).
        if let apiKey = dict["api_key"]?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
            return Credentials(accessKeyId: apiKey, accessKeySecret: "")
        }

        // Format 2: Legacy OAuth 2.0 paired credentials.
        if let id = dict["access_key_id"]?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
           let secret = dict["access_key_secret"]?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty {
            return Credentials(accessKeyId: id, accessKeySecret: secret)
        }

        return nil
    }

    /// Save (or overwrite) both credentials. No-op if either input is empty.
    public func saveCredentials(accessKeyId: String, accessKeySecret: String) {
        let trimmedId = accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = accessKeySecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty, !trimmedSecret.isEmpty,
              let idData = trimmedId.data(using: .utf8),
              let secretData = trimmedSecret.data(using: .utf8) else { return }
        keychain.save(idData, service: serviceName, account: accessKeyIdAccount)
        keychain.save(secretData, service: serviceName, account: accessKeySecretAccount)
        DebugLogger.shared.log("HERE credentials saved to Keychain")
    }

    /// Wipe both credentials. Used by account deletion / debug reset.
    public func clearCredentials() {
        keychain.delete(service: serviceName, account: accessKeyIdAccount)
        keychain.delete(service: serviceName, account: accessKeySecretAccount)
        DebugLogger.shared.log("HERE credentials cleared from Keychain")
    }

    public func hasCredentials() -> Bool {
        return loadCredentials() != nil
    }
}
