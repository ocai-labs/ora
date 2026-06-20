//
//  Permissions.swift
//  ora
//
//  Shared, observable snapshot of the two permissions the onboarding
//  flow needs to talk about: microphone (via AVFoundation) and
//  accessibility (via AXIsProcessTrusted). This is a UI-layer concern
//  only — the dictation pipeline still reads MicrophonePermission.status
//  and Paster.isTrusted directly at hotkey time. See
//  docs/superpowers/specs/2026-04-09-onboarding-wire-up-design.md
//  § Non-goals for why the two sources are not unified.
//

import AVFoundation
import AppKit
import ApplicationServices
import Observation

@MainActor
@Observable
final class Permissions {
    // MARK: - Observable state

    /// Current mic authorization, snapshotted from AVFoundation.
    /// Refreshed on init, after `requestMicrophone()`, and by the
    /// monitoring task while the onboarding window is visible.
    private(set) var microphoneStatus: AVAuthorizationStatus

    /// Whether the process is currently trusted for Accessibility.
    /// AX does not expose a "denied" state — only trusted / not.
    private(set) var accessibilityStatus: Bool

    // MARK: - Computed

    var microphoneGranted: Bool { microphoneStatus == .authorized }
    var accessibilityGranted: Bool { accessibilityStatus }

    /// Gate for launch-time onboarding logic and for `GetStartedView`'s
    /// "all green" footer button.
    var allPermissionsGranted: Bool {
        microphoneGranted && accessibilityGranted
    }

    // MARK: - Init

    init() {
        self.microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        self.accessibilityStatus = AXIsProcessTrusted()
    }

    // MARK: - Microphone

    /// Requests mic access if not yet determined, otherwise opens the
    /// relevant System Settings pane so the user can flip it manually.
    /// Always refreshes `microphoneStatus` at the end.
    func requestMicrophone() async {
        let current = MicrophonePermission.status

        switch current {
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            microphoneStatus = granted ? .authorized : .denied
        case .denied:
            openMicrophoneSettings()
            microphoneStatus = .denied
        case .authorized:
            microphoneStatus = .authorized
        }
    }

    func refreshMicrophoneStatus() {
        switch MicrophonePermission.status {
        case .authorized:    microphoneStatus = .authorized
        case .denied:        microphoneStatus = .denied
        case .notDetermined: microphoneStatus = .notDetermined
        }
    }

    func openMicrophoneSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Accessibility

    func refreshAccessibilityStatus() {
        accessibilityStatus = AXIsProcessTrusted()
    }

    /// High-level "make accessibility happen" entry point for UI code.
    /// Idempotent if already granted. Otherwise: seeds the TCC entry
    /// (so Ora appears in the Accessibility list) AND opens System
    /// Settings to the Accessibility pane so the user sees where to
    /// flip the toggle. Mirrors `requestMicrophone`'s contract of
    /// "click does something visible."
    func requestAccessibility() {
        if accessibilityGranted { return }
        // Seed the TCC entry first — without this, Ora isn't in the
        // Accessibility list when the pane opens and the user has to
        // discover the "+" button on their own.
        _ = Paster.requestTrust(prompt: true)
        openAccessibilitySettings()
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Monitoring

    @ObservationIgnored
    private var monitoringTask: Task<Void, Never>?

    /// Starts polling both permission statuses at the given interval.
    /// Idempotent — calling twice is a no-op. Call `stopMonitoring()`
    /// to tear it down. Intended lifetime: `onAppear`/`onDisappear` of
    /// the onboarding window.
    func startMonitoring(interval: Duration = .milliseconds(500)) {
        guard monitoringTask == nil else { return }
        // Weak self: teardown relies on the onboarding window's
        // onDisappear, and SwiftUI keeps scene-backed windows alive
        // after dismissal — a strong capture would keep this Permissions
        // instance (and the 2 Hz poll) running for the process lifetime
        // if onDisappear ever failed to fire.
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { break }
                self.refreshMicrophoneStatus()
                self.refreshAccessibilityStatus()
            }
        }
    }

    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }
}
