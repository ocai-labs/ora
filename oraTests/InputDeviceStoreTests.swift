//
//  InputDeviceStoreTests.swift
//  oraTests
//
//  Exercises the parts of InputDeviceStore that don't depend on real
//  Core Audio hardware: persistence round-trip via Preferences and the
//  "is System Default checked?" helper. The HAL enumeration path
//  (refresh / resolveSelectedDeviceID) is verified manually on hardware.
//

import Foundation
import Testing
@testable import ora

@MainActor
struct InputDeviceStoreTests {
    @Test("fresh store reads nil selectedUID from preferences")
    func initialSelectedUIDIsNil() {
        let suiteName = "ora.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = Preferences(defaults: defaults)
        let store = InputDeviceStore(preferences: prefs)
        #expect(store.selectedUID == nil)
    }

    @Test("select(uid:) updates published value and persists through preferences")
    func selectWritesToPrefs() {
        let suiteName = "ora.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = Preferences(defaults: defaults)
        let store = InputDeviceStore(preferences: prefs)

        store.select(uid: "BuiltInMicrophoneDevice")

        #expect(store.selectedUID == "BuiltInMicrophoneDevice")
        #expect(prefs.selectedInputDeviceUID == "BuiltInMicrophoneDevice")
    }

    @Test("select(uid: nil) clears the selection")
    func selectNilClears() {
        let suiteName = "ora.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = Preferences(defaults: defaults)
        prefs.selectedInputDeviceUID = "BuiltInMicrophoneDevice"
        let store = InputDeviceStore(preferences: prefs)

        store.select(uid: nil)

        #expect(store.selectedUID == nil)
        #expect(prefs.selectedInputDeviceUID == nil)
    }

    @Test("store hydrates selectedUID from preferences on init")
    func initHydratesFromPrefs() {
        let suiteName = "ora.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = Preferences(defaults: defaults)
        prefs.selectedInputDeviceUID = "AirPodsProDevice"

        let store = InputDeviceStore(preferences: prefs)
        #expect(store.selectedUID == "AirPodsProDevice")
    }

    @Test("isSystemDefaultChecked: true when selectedUID is nil")
    func systemDefaultCheckedWhenNil() {
        #expect(InputDeviceStore.isSystemDefaultChecked(selectedUID: nil, devices: []) == true)
    }

    @Test("isSystemDefaultChecked: true when selectedUID is stale (not in devices)")
    func systemDefaultCheckedWhenStale() {
        let devices = [
            InputDevice(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", audioDeviceID: 42)
        ]
        #expect(
            InputDeviceStore.isSystemDefaultChecked(selectedUID: "GoneDevice", devices: devices) == true
        )
    }

    @Test("isSystemDefaultChecked: false when selectedUID matches a current device")
    func systemDefaultUncheckedWhenMatched() {
        let devices = [
            InputDevice(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", audioDeviceID: 42)
        ]
        #expect(
            InputDeviceStore.isSystemDefaultChecked(
                selectedUID: "BuiltInMicrophoneDevice",
                devices: devices
            ) == false
        )
    }
}
