//
//  PreferencesInputDeviceTests.swift
//  oraTests
//
//  Round-trips `selectedInputDeviceUID` through a private UserDefaults
//  suite so the global `standard` defaults stay untouched by tests.
//

import Foundation
import Testing
@testable import ora

@MainActor
struct PreferencesInputDeviceTests {
    @Test("selectedInputDeviceUID defaults to nil on a fresh suite")
    func defaultsToNil() {
        let suiteName = "ora.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = Preferences(defaults: defaults)
        #expect(prefs.selectedInputDeviceUID == nil)
    }

    @Test("setting selectedInputDeviceUID persists and re-reads across instances")
    func persistsAcrossInstances() {
        let suiteName = "ora.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = Preferences(defaults: defaults)
        prefs.selectedInputDeviceUID = "BuiltInMicrophoneDevice"

        let reloaded = Preferences(defaults: defaults)
        #expect(reloaded.selectedInputDeviceUID == "BuiltInMicrophoneDevice")
    }

    @Test("setting selectedInputDeviceUID back to nil clears persistence")
    func clearsToNil() {
        let suiteName = "ora.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = Preferences(defaults: defaults)
        prefs.selectedInputDeviceUID = "BuiltInMicrophoneDevice"
        prefs.selectedInputDeviceUID = nil

        let reloaded = Preferences(defaults: defaults)
        #expect(reloaded.selectedInputDeviceUID == nil)
    }
}
