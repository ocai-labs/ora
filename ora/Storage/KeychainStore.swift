//
//  KeychainStore.swift
//  ora
//
//  Tiny Keychain wrapper for per-provider API keys. One generic-password
//  item per provider id, keyed by a fixed service string so all ora
//  credentials group together in Keychain Access.app.
//
//  Ora isn't sandboxed (see ora.entitlements), so these items land in
//  the default login keychain without any keychain-access-group gymnastics.
//

import Foundation
import Security

enum KeychainStore {
    private static let service = "co.ora.apikeys"

    enum Failure: Error, LocalizedError {
        case osStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .osStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String?
                return "Keychain error: \(message ?? "OSStatus \(status)")"
            }
        }
    }

    /// Stores `key` under `provider`. Overwrites any existing value.
    /// Pass an empty string to delete — we treat "" as "no credential"
    /// rather than persisting a zero-length secret.
    static func setAPIKey(_ key: String, provider: String) throws {
        if key.isEmpty {
            try removeAPIKey(provider: provider)
            return
        }
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider,
        ]
        // Accessibility is included on update too, so items created by
        // older builds migrate to the intended protection class instead
        // of keeping whatever they were added with.
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus != errSecSuccess { throw Failure.osStatus(addStatus) }
        default:
            throw Failure.osStatus(status)
        }
    }

    /// Returns the stored key for `provider`, or `nil` if missing.
    ///
    /// Unexpected read failures (locked keychain, denied ACL prompt,
    /// auth failure) also return `nil` — the dictation preflight treats
    /// that as "not configured", which is the safest visible fallback —
    /// but they're logged so "it keeps asking for my key" is
    /// diagnosable from Console instead of looking identical to a
    /// missing credential.
    static func apiKey(provider: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if Self.isUnexpectedReadStatus(status) {
            NSLog("[KeychainStore] SecItemCopyMatching(\(provider)) failed: OSStatus=\(status)")
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8),
              !string.isEmpty
        else { return nil }
        return string
    }

    /// Deletes the stored key for `provider`. Deleting a key that was
    /// never stored is success; any other failure throws — callers in
    /// the "clear my key" flow must not report success while the old
    /// credential is still in the keychain.
    static func removeAPIKey(provider: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard Self.deletionSucceeded(status) else {
            throw Failure.osStatus(status)
        }
    }

    // MARK: - Status classification (pure, unit-tested)

    /// `errSecItemNotFound` counts as success for deletion: the goal
    /// state ("no credential stored") is already true.
    static func deletionSucceeded(_ status: OSStatus) -> Bool {
        status == errSecSuccess || status == errSecItemNotFound
    }

    /// True for read statuses that mean "something went wrong" rather
    /// than "found" / "not stored" — these deserve a log line because
    /// the caller-visible result (nil) is indistinguishable from a
    /// missing key.
    static func isUnexpectedReadStatus(_ status: OSStatus) -> Bool {
        status != errSecSuccess && status != errSecItemNotFound
    }
}
