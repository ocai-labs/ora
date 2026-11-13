//
//  PreferencesInterfaceTests.swift
//  oraTests
//
//  Defaults and the Pill/Panel → independent-toggles migration for the
//  Interface / Dictation preferences, plus the pure overlay layout and
//  tint helpers. Each test uses a private UserDefaults suite so the
//  global `standard` defaults stay untouched.
//

import Foundation
import Testing
@testable import ora

@MainActor
struct PreferencesInterfaceTests {
    private func withSuite(_ body: (UserDefaults) -> Void) {
        let suiteName = "ora.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    @Test("fresh install defaults")
    func freshDefaults() {
        withSuite { defaults in
            let prefs = Preferences(defaults: defaults)
            #expect(prefs.activationMode == .toggle)
            #expect(prefs.showRecordingPill)
            #expect(prefs.pillPosition == .bottom)
            #expect(prefs.showLivePreview)
            #expect(prefs.returnFinishesDictation)
            #expect(prefs.overlayTintHex == nil)
            #expect(prefs.overlayTintStrength == OverlayTint.defaultStrength)
        }
    }

    @Test("a stored Hold activation mode is kept")
    func storedHoldKept() {
        withSuite { defaults in
            defaults.set("hold", forKey: "ora.activationMode")
            #expect(Preferences(defaults: defaults).activationMode == .hold)
        }
    }

    @Test("legacy Panel style migrates to live transcription on")
    func migratesPanel() {
        withSuite { defaults in
            defaults.set(true, forKey: "ora.hasCompletedOnboarding")
            defaults.set("panel", forKey: "ora.overlayStyle")
            let prefs = Preferences(defaults: defaults)
            #expect(prefs.showLivePreview)
            #expect(prefs.showRecordingPill)
            #expect(prefs.pillPosition == .bottom)
            #expect(defaults.object(forKey: "ora.overlayStyle") == nil)
            #expect(defaults.object(forKey: "ora.showLivePreview") as? Bool == true)
        }
    }

    @Test("legacy Pill style migrates to live transcription off")
    func migratesPill() {
        withSuite { defaults in
            defaults.set("pill", forKey: "ora.overlayStyle")
            let prefs = Preferences(defaults: defaults)
            #expect(!prefs.showLivePreview)
            #expect(prefs.showRecordingPill)
            #expect(defaults.object(forKey: "ora.overlayStyle") == nil)
            // Re-reading keeps the migrated value.
            #expect(!Preferences(defaults: defaults).showLivePreview)
        }
    }

    @Test("existing user who never chose a style keeps the old Pill default")
    func existingUserWithoutStyle() {
        withSuite { defaults in
            defaults.set(true, forKey: "ora.hasCompletedOnboarding")
            #expect(!Preferences(defaults: defaults).showLivePreview)
        }
    }

    @Test("new install's live transcription default survives finishing onboarding")
    func freshDefaultIsPersisted() {
        withSuite { defaults in
            let prefs = Preferences(defaults: defaults)
            prefs.hasCompletedOnboarding = true
            #expect(Preferences(defaults: defaults).showLivePreview)
        }
    }

    @Test("an explicit showLivePreview wins over a leftover legacy key")
    func explicitWinsOverLegacy() {
        withSuite { defaults in
            defaults.set(false, forKey: "ora.showLivePreview")
            defaults.set("panel", forKey: "ora.overlayStyle")
            #expect(!Preferences(defaults: defaults).showLivePreview)
        }
    }

    @Test("interface settings persist across instances")
    func persists() {
        withSuite { defaults in
            let prefs = Preferences(defaults: defaults)
            prefs.showRecordingPill = false
            prefs.pillPosition = .top
            prefs.showLivePreview = false
            prefs.returnFinishesDictation = false
            prefs.overlayTintHex = "#0A84FF"
            prefs.overlayTintStrength = 0.6

            let reloaded = Preferences(defaults: defaults)
            #expect(!reloaded.showRecordingPill)
            #expect(reloaded.pillPosition == .top)
            #expect(!reloaded.showLivePreview)
            #expect(!reloaded.returnFinishesDictation)
            #expect(reloaded.overlayTintHex == "#0A84FF")
            #expect(reloaded.overlayTintStrength == 0.6)
        }
    }

    @Test("reset overlay glass restores Automatic and the default strength")
    func resetGlass() {
        withSuite { defaults in
            let prefs = Preferences(defaults: defaults)
            prefs.overlayTintHex = "#FF375F"
            prefs.overlayTintStrength = 0.8
            prefs.resetOverlayGlass()
            #expect(prefs.overlayTintHex == nil)
            #expect(prefs.overlayTintStrength == OverlayTint.defaultStrength)
            #expect(defaults.object(forKey: "ora.overlayTintHex") == nil)
        }
    }

    @Test("a malformed stored tint falls back to Automatic")
    func malformedTint() {
        withSuite { defaults in
            defaults.set("not a colour", forKey: "ora.overlayTintHex")
            #expect(Preferences(defaults: defaults).overlayTintHex == nil)
        }
    }
}

@MainActor
struct OverlayTintTests {
    @Test("hex round-trips")
    func hexRoundTrip() throws {
        let rgb = try #require(OverlayTint.components(fromHex: "#0A84FF"))
        #expect(OverlayTint.hex(red: rgb.red, green: rgb.green, blue: rgb.blue) == "#0A84FF")
        #expect(OverlayTint.components(fromHex: "#12345") == nil)
        #expect(OverlayTint.components(fromHex: "zzzzzz") == nil)
    }

    @Test("Automatic foreground follows the colour scheme")
    func automaticForeground() {
        #expect(OverlayTint.prefersLightForeground(tintLuminance: nil, strength: 0.9, isDark: true))
        #expect(!OverlayTint.prefersLightForeground(tintLuminance: nil, strength: 0.9, isDark: false))
    }

    @Test("a strong tint picks foreground by its luminance")
    func strongTintForeground() {
        let yellow = OverlayTint.relativeLuminance(red: 1, green: 0.9, blue: 0.2)
        let navy = OverlayTint.relativeLuminance(red: 0.05, green: 0.1, blue: 0.4)
        // Light tint dominating dark glass → dark foreground.
        #expect(!OverlayTint.prefersLightForeground(tintLuminance: yellow, strength: 0.9, isDark: true))
        // Dark tint dominating light glass → light foreground.
        #expect(OverlayTint.prefersLightForeground(tintLuminance: navy, strength: 0.9, isDark: false))
        // A faint tint leaves the scheme in charge.
        #expect(OverlayTint.prefersLightForeground(tintLuminance: yellow, strength: 0.1, isDark: true))
        #expect(!OverlayTint.prefersLightForeground(tintLuminance: navy, strength: 0.1, isDark: false))
    }
}

@MainActor
struct OverlayLayoutTests {
    private func layout(
        pill: Bool, _ position: PillPosition, bubble: Bool,
        phase: OverlayPhase = .recording, supports: Bool = true
    ) -> OverlayLayout {
        OverlayLayout(
            showPill: pill, position: position, showLivePreview: bubble,
            phase: phase, modelSupportsLivePreview: supports)
    }

    @Test("pill bottom + bubble is the classic panel stack")
    func bottomWithBubble() {
        let l = layout(pill: true, .bottom, bubble: true)
        #expect(!l.top)
        #expect(l.bottom == .init(pill: .always, bubble: true))
    }

    @Test("pill bottom without bubble is a lone bottom pill")
    func bottomAlone() {
        let l = layout(pill: true, .bottom, bubble: false)
        #expect(!l.top)
        #expect(l.bottom == .init(pill: .always, bubble: false))
        // Unsupported model behaves the same.
        #expect(layout(pill: true, .bottom, bubble: true, supports: false).bottom
            == .init(pill: .always, bubble: false))
    }

    @Test("pill top + bubble splits into two panels")
    func topWithBubble() {
        let l = layout(pill: true, .top, bubble: true)
        #expect(l.top)
        #expect(l.bottom == .init(pill: .never, bubble: true))
        // No bubble possible → no bottom panel at all.
        #expect(layout(pill: true, .top, bubble: true, supports: false).bottom == nil)
        #expect(layout(pill: true, .top, bubble: false).bottom == nil)
    }

    @Test("hidden pill + bubble uses a stand-in pill at the bottom")
    func hiddenWithBubble() {
        let l = layout(pill: false, .top, bubble: true)
        #expect(!l.top)
        #expect(l.bottom == .init(pill: .standIn, bubble: true))
        #expect(layout(pill: false, .bottom, bubble: true, supports: false).bottom
            == .init(pill: .standIn, bubble: false))
    }

    @Test("nothing visible while recording / transcribing, but errors still get a pill")
    func neither() {
        #expect(layout(pill: false, .bottom, bubble: false).isEmpty)
        #expect(layout(pill: false, .bottom, bubble: false, phase: .transcribing).isEmpty)

        let bottomError = layout(pill: false, .bottom, bubble: false, phase: .errorNoMic)
        #expect(!bottomError.top)
        #expect(bottomError.bottom == .init(pill: .always, bubble: false))

        let topError = layout(pill: false, .top, bubble: false, phase: .errorGeneric("x"))
        #expect(topError.top)
        #expect(topError.bottom == nil)
    }
}
