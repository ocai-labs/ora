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

/// Which dictation overlay the user sees while recording.
/// - `pill`: the original capsule at the top of the screen — waveform
///   only, never runs live-preview inference.
/// - `panel`: fixed-height panel at the bottom of the screen — small
///   waveform plus live partial-transcript text (when the selected
///   model supports it; otherwise renders compact, pill-like).
/// See docs/2026-06-10-streaming-live-preview-spec.md §5.4/§6.
enum OverlayStyle: String, CaseIterable, Identifiable {
    case pill
    case panel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pill: "Pill"
        case .panel: "Panel"
        }
    }

    var description: String {
        switch self {
        case .pill: "A compact capsule at the top of the screen."
        case .panel: "A panel at the bottom with live transcription preview."
        }
    }
}

/// How the activation hotkey arms and disarms the recorder.
/// - `hold`: hold the key, release to stop (the original default).
/// - `toggle`: first press starts recording, second press stops it.
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
        static let overlayStyle = "ora.overlayStyle"
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

    var overlayStyle: OverlayStyle {
        didSet { defaults.set(overlayStyle.rawValue, forKey: Key.overlayStyle) }
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
            self.activationMode = .hold
        }
        if let raw = defaults.string(forKey: Key.appearance),
           let mode = AppearanceMode(rawValue: raw) {
            self.appearance = mode
        } else {
            self.appearance = .system
        }
        if let raw = defaults.string(forKey: Key.overlayStyle),
           let style = OverlayStyle(rawValue: raw) {
            self.overlayStyle = style
        } else {
            self.overlayStyle = .pill
        }
        self.notificationSoundEnabled = (defaults.object(forKey: Key.notificationSoundEnabled) as? Bool) ?? true
        self.notificationSoundName = defaults.string(forKey: Key.notificationSoundName) ?? "Pop"
        self.selectedInputDeviceUID = defaults.string(forKey: Key.selectedInputDeviceUID)
        self.nemotronUnifiedLanguage = defaults.string(forKey: Key.nemotronUnifiedLanguage) ?? "auto"
        self.nemotronStreamingLanguage = defaults.string(forKey: Key.nemotronStreamingLanguage) ?? "auto"
    }
}
