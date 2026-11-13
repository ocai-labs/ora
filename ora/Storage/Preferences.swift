//
//  Preferences.swift
//  ora
//
//  Persistent user preferences, backed by UserDefaults.
//  Observed by SwiftUI via @Observable; mutations flow straight to defaults
//  so every setting survives an app quit-and-relaunch.
//

import Foundation
import Observation

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
}

/// Where the recording pill sits while dictating. The live
/// transcription bubble is always at the bottom, whichever is chosen.
enum PillPosition: String, CaseIterable, Identifiable {
    case top
    case bottom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .top: "Top"
        case .bottom: "Bottom"
        }
    }
}

/// Tint of the overlay glass (pill + live transcription bubble).
/// `nil` hex = Automatic (untinted glass that follows Appearance).
/// The presets are just named hex values; any other hex is a custom
/// colour picked with the ColorPicker.
enum OverlayTint {
    struct Preset: Identifiable, Equatable {
        let name: String
        let hex: String
        var id: String { hex }
    }

    static let presets: [Preset] = [
        Preset(name: "Graphite", hex: "#8E8E93"),
        Preset(name: "Blue", hex: "#0A84FF"),
        Preset(name: "Purple", hex: "#BF5AF2"),
        Preset(name: "Pink", hex: "#FF375F"),
        Preset(name: "Orange", hex: "#FF9F0A"),
        Preset(name: "Green", hex: "#30D158"),
    ]

    static let defaultStrength = 0.3
    static let strengthRange: ClosedRange<Double> = 0...0.9

    /// "#RRGGBB" → sRGB components in 0...1, or nil if malformed.
    static func components(fromHex hex: String) -> (red: Double, green: Double, blue: Double)? {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }

    /// sRGB components (clamped to 0...1) → "#RRGGBB".
    static func hex(red: Double, green: Double, blue: Double) -> String {
        func byte(_ v: Double) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// WCAG relative luminance of an sRGB colour (0 = black, 1 = white).
    static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// Whether overlay foreground (waveform, spinner, text) should be
    /// light (white) rather than dark. Approximates the surface as the
    /// untinted glass's own brightness for the colour scheme blended
    /// with the tint at `strength`; light foreground below the
    /// midpoint. With Automatic (`tintLuminance == nil`) this reduces
    /// to the colour scheme — i.e. `.primary`.
    static func prefersLightForeground(tintLuminance: Double?, strength: Double, isDark: Bool) -> Bool {
        let base = isDark ? 0.08 : 0.85
        guard let tintLuminance else { return isDark }
        let s = min(max(strength, 0), 1)
        let surface = base * (1 - s) + tintLuminance * s
        return surface < 0.4
    }
}

/// How the activation hotkey arms and disarms the recorder.
/// - `hold`: hold the key, release to stop.
/// - `toggle`: first press starts recording, second press stops it
///   (the default for new installs).
enum ActivationMode: String, CaseIterable, Identifiable {
    case hold
    case toggle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hold: "Hold"
        case .toggle: "Toggle"
        }
    }

    var description: String {
        switch self {
        case .hold: "Hold the key to dictate, release to stop."
        case .toggle: "Press once to start, press again to stop."
        }
    }
}

@Observable
final class Preferences {
    static let shared = Preferences()
    static let defaultModelId = FluidAudioTranscriber.modelId

    /// Id prefixes of models dropped from the catalog — see init.
    /// Parakeet v3 was replaced by Parakeet Ultra (the same model,
    /// post-trained) and v2 retired, so both move to the default.
    static let removedModelPrefixes = ["whisper-", "qwen3-asr-", "parakeet-v2", "parakeet-v3"]

    private enum Key {
        static let selectedModelId = "ora.selectedModelId"
        static let autoPaste = "ora.autoPaste"
        static let hasCompletedOnboarding = "ora.hasCompletedOnboarding"
        static let showInDock = "ora.showInDock"
        static let showInStatusBar = "ora.showInStatusBar"
        static let launchAtLogin = "ora.launchAtLogin"
        static let activationKey = "ora.activationKey"
        static let activationMode = "ora.activationMode"
        static let appearance = "ora.appearance"
        static let notificationSoundEnabled = "ora.notificationSoundEnabled"
        static let notificationSoundName = "ora.notificationSoundName"
        static let selectedInputDeviceUID = "ora.selectedInputDeviceUID"
        /// Legacy Pill/Panel display style — read once for migration
        /// to `showLivePreview`, then removed.
        static let legacyOverlayStyle = "ora.overlayStyle"
        static let showRecordingPill = "ora.showRecordingPill"
        static let pillPosition = "ora.pillPosition"
        static let showLivePreview = "ora.showLivePreview"
        static let overlayTintHex = "ora.overlayTintHex"
        static let overlayTintStrength = "ora.overlayTintStrength"
        static let returnFinishesDictation = "ora.returnFinishesDictation"
        static let saveHistory = "ora.saveHistory"
        static let nemotronUnifiedLanguage = "ora.nemotronUnifiedLanguage"
        static let nemotronStreamingLanguage = "ora.nemotronStreamingLanguage"
    }

    private let defaults: UserDefaults

    /// Fired after `selectedModelId` changes to a *different* value, so
    /// the DictationCoordinator can prewarm the newly-selected model off
    /// the first-dictation path. `@ObservationIgnored` so the `@Observable`
    /// macro treats it as plumbing rather than observable UI state. Swift
    /// skips property observers during init, so the restore at launch
    /// doesn't fire it — the coordinator does a one-shot launch prewarm
    /// separately.
    @ObservationIgnored
    var onSelectedModelChanged: ((String?) -> Void)?

    var selectedModelId: String? {
        didSet {
            defaults.set(selectedModelId, forKey: Key.selectedModelId)
            if selectedModelId != oldValue { onSelectedModelChanged?(selectedModelId) }
        }
    }

    var autoPaste: Bool {
        didSet { defaults.set(autoPaste, forKey: Key.autoPaste) }
    }

    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }

    var showInDock: Bool {
        didSet { defaults.set(showInDock, forKey: Key.showInDock) }
    }

    var showInStatusBar: Bool {
        didSet { defaults.set(showInStatusBar, forKey: Key.showInStatusBar) }
    }

    var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }

    var activationKey: ActivationKey {
        didSet { defaults.set(activationKey.rawValue, forKey: Key.activationKey) }
    }

    var activationMode: ActivationMode {
        didSet { defaults.set(activationMode.rawValue, forKey: Key.activationMode) }
    }

    var appearance: AppearanceMode {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    /// Show the waveform pill while recording / transcribing. Errors
    /// always show a pill regardless, so failures are never invisible.
    var showRecordingPill: Bool {
        didSet { defaults.set(showRecordingPill, forKey: Key.showRecordingPill) }
    }

    var pillPosition: PillPosition {
        didSet { defaults.set(pillPosition.rawValue, forKey: Key.pillPosition) }
    }

    /// Show the live transcription bubble at the bottom of the screen
    /// (and run the live-preview engine) when the selected model
    /// supports it.
    var showLivePreview: Bool {
        didSet { defaults.set(showLivePreview, forKey: Key.showLivePreview) }
    }

    /// Overlay glass tint as "#RRGGBB"; nil = Automatic (untinted).
    var overlayTintHex: String? {
        didSet {
            if let overlayTintHex {
                defaults.set(overlayTintHex, forKey: Key.overlayTintHex)
            } else {
                defaults.removeObject(forKey: Key.overlayTintHex)
            }
        }
    }

    /// How strongly the tint colours the glass, 0...0.9.
    var overlayTintStrength: Double {
        didSet { defaults.set(overlayTintStrength, forKey: Key.overlayTintStrength) }
    }

    /// Whether Return finishes (stops + pastes) a recording. The Return
    /// press is consumed, so it never reaches the focused app.
    var returnFinishesDictation: Bool {
        didSet { defaults.set(returnFinishesDictation, forKey: Key.returnFinishesDictation) }
    }

    /// Keep the last `HistoryStore.maxEntries` recordings + transcripts
    /// on this Mac (History page). Turning it off is paired with
    /// clearing the history in the UI.
    var saveHistory: Bool {
        didSet { defaults.set(saveHistory, forKey: Key.saveHistory) }
    }

    func resetOverlayGlass() {
        overlayTintHex = nil
        overlayTintStrength = OverlayTint.defaultStrength
    }

    /// Fired when `nemotronUnifiedLanguage` changes. DictationCoordinator
    /// uses it to re-warm the model: the language is baked into the
    /// loaded Nemotron encoder, so a change means a reload.
    @ObservationIgnored
    var onNemotronUnifiedLanguageChanged: (() -> Void)?

    /// Language code the Nemotron Unified model is told to transcribe
    /// ("auto" or one of its 25 ISO 639-1 codes, e.g. "fr"). Forcing the
    /// language is what stops a French speaker getting English words —
    /// see NemotronUnifiedTranscriber.
    var nemotronUnifiedLanguage: String {
        didSet {
            defaults.set(nemotronUnifiedLanguage, forKey: Key.nemotronUnifiedLanguage)
            if nemotronUnifiedLanguage != oldValue { onNemotronUnifiedLanguageChanged?() }
        }
    }

    /// Locale the Nemotron 3.5 Streaming model is told to transcribe
    /// ("auto" or a prompt-dictionary key such as "zh-CN" / "ko-KR").
    /// Applied per session, so a change needs no model reload — see
    /// NemotronStreamingTranscriber.
    var nemotronStreamingLanguage: String {
        didSet { defaults.set(nemotronStreamingLanguage, forKey: Key.nemotronStreamingLanguage) }
    }

    var notificationSoundEnabled: Bool {
        didSet { defaults.set(notificationSoundEnabled, forKey: Key.notificationSoundEnabled) }
    }

    var notificationSoundName: String {
        didSet { defaults.set(notificationSoundName, forKey: Key.notificationSoundName) }
    }

    /// UID of the input device the user pinned for dictation. `nil`
    /// means "Follow System Default" — the recorder uses whatever the
    /// system default input is at record time. Stable across reboots
    /// and reconnects (HAL `kAudioDevicePropertyDeviceUID`).
    var selectedInputDeviceUID: String? {
        didSet {
            if let selectedInputDeviceUID {
                defaults.set(selectedInputDeviceUID, forKey: Key.selectedInputDeviceUID)
            } else {
                defaults.removeObject(forKey: Key.selectedInputDeviceUID)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Whisper (WhisperKit), Qwen3-ASR (MLX) and Parakeet v2/v3
        // were removed in 0.7.0. A stored selection of one would otherwise resolve to
        // no transcriber and every dictation would fail with "no model",
        // so fall back to the default. Their downloaded files are left
        // on disk.
        let storedModelId = defaults.string(forKey: Key.selectedModelId)
        if let storedModelId, Self.removedModelPrefixes.contains(where: storedModelId.hasPrefix) {
            self.selectedModelId = Self.defaultModelId
            defaults.set(Self.defaultModelId, forKey: Key.selectedModelId)
        } else {
            self.selectedModelId = storedModelId ?? Self.defaultModelId
        }
        self.autoPaste = (defaults.object(forKey: Key.autoPaste) as? Bool) ?? true
        self.hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
        self.showInDock = (defaults.object(forKey: Key.showInDock) as? Bool) ?? false
        self.showInStatusBar = (defaults.object(forKey: Key.showInStatusBar) as? Bool) ?? true
        self.launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        if let raw = defaults.string(forKey: Key.activationKey),
           let key = ActivationKey(rawValue: raw) {
            self.activationKey = key
        } else {
            self.activationKey = .default
        }
        if let raw = defaults.string(forKey: Key.activationMode),
           let mode = ActivationMode(rawValue: raw) {
            self.activationMode = mode
        } else {
            // Toggle is the default for new installs; a stored
            // choice (including an explicit Hold) is kept above.
            self.activationMode = .toggle
        }
        if let raw = defaults.string(forKey: Key.appearance),
           let mode = AppearanceMode(rawValue: raw) {
            self.appearance = mode
        } else {
            self.appearance = .system
        }
        self.showRecordingPill = (defaults.object(forKey: Key.showRecordingPill) as? Bool) ?? true
        if let raw = defaults.string(forKey: Key.pillPosition),
           let position = PillPosition(rawValue: raw) {
            self.pillPosition = position
        } else {
            self.pillPosition = .bottom
        }
        if let stored = defaults.object(forKey: Key.showLivePreview) as? Bool {
            self.showLivePreview = stored
        } else if let legacy = defaults.string(forKey: Key.legacyOverlayStyle) {
            // Pre-0.8 "Dictation Display" picker: Panel was the live
            // preview style, Pill the waveform-only one. Persist the
            // migrated value and drop the old key so this runs once.
            let migrated = legacy == "panel"
            self.showLivePreview = migrated
            defaults.set(migrated, forKey: Key.showLivePreview)
            defaults.removeObject(forKey: Key.legacyOverlayStyle)
        } else {
            // Nothing stored: an existing user who never touched the old
            // picker was on its default, Pill (no live preview); keep
            // that. New installs get the live transcription bubble.
            // Persisted right away: otherwise a new install would flip
            // to "existing user" once onboarding completes.
            let resolved = !defaults.bool(forKey: Key.hasCompletedOnboarding)
            self.showLivePreview = resolved
            defaults.set(resolved, forKey: Key.showLivePreview)
        }
        if let hex = defaults.string(forKey: Key.overlayTintHex),
           OverlayTint.components(fromHex: hex) != nil {
            self.overlayTintHex = hex
        } else {
            self.overlayTintHex = nil
        }
        if let strength = defaults.object(forKey: Key.overlayTintStrength) as? Double {
            self.overlayTintStrength = min(max(strength, OverlayTint.strengthRange.lowerBound), OverlayTint.strengthRange.upperBound)
        } else {
            self.overlayTintStrength = OverlayTint.defaultStrength
        }
        self.returnFinishesDictation = (defaults.object(forKey: Key.returnFinishesDictation) as? Bool) ?? true
        self.saveHistory = (defaults.object(forKey: Key.saveHistory) as? Bool) ?? true
        self.notificationSoundEnabled = (defaults.object(forKey: Key.notificationSoundEnabled) as? Bool) ?? true
        self.notificationSoundName = defaults.string(forKey: Key.notificationSoundName) ?? "Pop"
        self.selectedInputDeviceUID = defaults.string(forKey: Key.selectedInputDeviceUID)
        self.nemotronUnifiedLanguage = defaults.string(forKey: Key.nemotronUnifiedLanguage) ?? "auto"
        self.nemotronStreamingLanguage = defaults.string(forKey: Key.nemotronStreamingLanguage) ?? "auto"
    }
}
