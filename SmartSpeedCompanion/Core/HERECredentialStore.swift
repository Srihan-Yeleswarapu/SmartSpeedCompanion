// HERECredentialStore.swift
// Loads HERE Platform access_key_id and access_key_secret from iOS Keychain
// (safer than Bundle plist — survives a jailbroken read on most builds).
// Wraps the existing KeychainHelper.
//
// Service:   com.speedsense.here
// Accounts:  access_key_id, access_key_secret
//
// HERERestSpeedLimitProvider returns nil if either credential is missing so
// the orchestrator's chain falls through to other providers instead of crashing.

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

    private init() {
        self.keychain = KeychainHelper.standard
    }

    public struct Credentials: Sendable {
        public let accessKeyId: String
        public let accessKeySecret: String
    }

    /// Returns nil if either credential is missing or unparseable.
    public func loadCredentials() -> Credentials? {
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
