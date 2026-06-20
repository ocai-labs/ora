//
//  MicrophonePermission.swift
//  ora
//
//  Thin wrapper around AVCaptureDevice's audio-permission APIs. Kept as a
//  dedicated file so the rest of the Audio layer can stay focused on the
//  capture graph and not reason about TCC state machines.
//
//  ## Sandbox + Info.plist requirements
//
//  Two separate things have to be in place for this to work, and the error
//  messages when one is missing are not always obvious:
//
//    1. `com.apple.security.device.audio-input` in `ora.entitlements`.
//       Without it, the sandbox blocks mic access before TCC is even
//       consulted and `AVCaptureDevice.authorizationStatus(for: .audio)`
//       can return `.authorized` while `AVAudioEngine` still produces
//       silence.
//
//    2. `INFOPLIST_KEY_NSMicrophoneUsageDescription` set in the target's
//       build settings (we use `GENERATE_INFOPLIST_FILE = YES`, so there
//       is no standalone Info.plist file — the key lives in pbxproj).
//       Without it, `requestAccess` crashes the app with a TCC violation
//       the first time it runs.
//
//  Both are wired as of M2. If either is removed the error surfaces at
//  the moment a recording is attempted, not at launch.
//

import AVFoundation

enum MicrophonePermission {
    enum Status {
        case authorized
        case denied
        case notDetermined
    }

    /// Current authorization status. Safe to call from any actor; the
    /// underlying AVFoundation API is thread-safe.
    static var status: Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .authorized
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    /// Prompts the user for microphone access if status is
    /// `.notDetermined`, otherwise returns immediately. Resolves to
    /// `true` iff the app is authorized after the call returns.
    ///
    /// Note: the system only shows the consent dialog once per install.
    /// If the user previously denied, this returns `false` without a
    /// prompt — the caller is responsible for telling them to flip the
    /// switch in System Settings.
    static func request() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
