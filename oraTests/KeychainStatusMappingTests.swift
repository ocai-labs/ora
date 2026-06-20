//
//  KeychainStatusMappingTests.swift
//  oraTests
//
//  Locks down the pure OSStatus classification behind KeychainStore's
//  error handling (review finding #4): deletion treats item-not-found
//  as success, and read failures other than not-found are flagged as
//  unexpected (they get logged instead of silently masquerading as
//  "no key configured"). No live keychain access here — the syscalls
//  themselves stay untested by design.
//

import Security
import Testing
@testable import ora

struct KeychainStatusMappingTests {

    @Test("deletion succeeds on success and on item-not-found")
    func deletionSuccessStatuses() {
        #expect(KeychainStore.deletionSucceeded(errSecSuccess))
        // The goal state ("no credential stored") is already true.
        #expect(KeychainStore.deletionSucceeded(errSecItemNotFound))
    }

    @Test("deletion fails on real errors")
    func deletionFailureStatuses() {
        #expect(!KeychainStore.deletionSucceeded(errSecAuthFailed))
        #expect(!KeychainStore.deletionSucceeded(errSecInteractionNotAllowed))
        #expect(!KeychainStore.deletionSucceeded(errSecNotAvailable))
    }

    @Test("read statuses: found and not-stored are expected; everything else is flagged")
    func readStatusClassification() {
        #expect(!KeychainStore.isUnexpectedReadStatus(errSecSuccess))
        #expect(!KeychainStore.isUnexpectedReadStatus(errSecItemNotFound))
        #expect(KeychainStore.isUnexpectedReadStatus(errSecAuthFailed))
        #expect(KeychainStore.isUnexpectedReadStatus(errSecInteractionNotAllowed))
        #expect(KeychainStore.isUnexpectedReadStatus(errSecUserCanceled))
    }

    @Test("Failure renders a human-readable description")
    func failureDescription() {
        let description = KeychainStore.Failure.osStatus(errSecAuthFailed).errorDescription
        #expect(description?.isEmpty == false)
        #expect(description?.contains("Keychain") == true)
    }
}
