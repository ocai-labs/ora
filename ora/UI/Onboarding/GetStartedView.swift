//
//  GetStartedView.swift
//  ora
//
//  Onboarding view that walks users through the permissions Ora needs.
//  Two modes: pass a real `Permissions` instance for the live onboarding
//  window, or leave `permissions` nil for previews/tests (mock mode
//  flips card statuses straight to `.granted` so the flow is still
//  exercisable from a SwiftUI preview).
//

import AVFoundation
import SwiftUI

// MARK: - Permission Item Model

enum PermissionStatus: String {
    case notRequested = "Not Requested"
    case granted = "Granted"
    case denied = "Denied"
}

enum PermissionKind: CaseIterable {
    case microphone
    case accessibility
}

struct PermissionItem: Identifiable {
    var id: PermissionKind { kind }
    let kind: PermissionKind
    let title: String
    let description: String
    let icon: String
    let steps: [String]
}

// MARK: - GetStartedView

struct GetStartedView: View {
    var realPermissions: Permissions?
    var onComplete: (() -> Void)?

    /// Only used when `realPermissions` is nil (previews / tests).
    @State private var mockStatuses: [PermissionKind: PermissionStatus]

    init(
        permissions: Permissions? = nil,
        onComplete: (() -> Void)? = nil,
        mockStatuses: [PermissionKind: PermissionStatus]? = nil
    ) {
        self.realPermissions = permissions
        self.onComplete = onComplete
        _mockStatuses = State(initialValue: mockStatuses ?? [:])
    }

    private static let standardAnimation = Animation.easeInOut(duration: 0.25)

    private static let permissionDefinitions: [PermissionItem] = [
        PermissionItem(
            kind: .microphone,
            title: "Microphone",
            description: "Required for voice input and speech recognition.",
            icon: "mic.fill",
            steps: [
                "A system dialog will appear asking for microphone access.",
                "Click \"Allow\" to grant permission.",
                "If denied, go to System Settings → Privacy & Security → Microphone and enable Ora.",
            ]
        ),
        PermissionItem(
            kind: .accessibility,
            title: "Accessibility",
            description: "Required to insert transcribed text into any application.",
            icon: "accessibility",
            steps: [
                "Open System Settings → Privacy & Security → Accessibility.",
                "Click the lock icon to make changes.",
                "Find Ora in the list and toggle it on.",
            ]
        ),
    ]

    private func status(for kind: PermissionKind) -> PermissionStatus {
        if let realPermissions {
            switch kind {
            case .microphone:
                if realPermissions.microphoneGranted { return .granted }
                if realPermissions.microphoneStatus == .denied
                    || realPermissions.microphoneStatus == .restricted {
                    return .denied
                }
                return .notRequested
            case .accessibility:
                // AX has no "denied" state — not trusted is rendered
                // as .notRequested so the user still sees the
                // "how to grant it" steps.
                return realPermissions.accessibilityGranted ? .granted : .notRequested
            }
        }
        return mockStatuses[kind] ?? .notRequested
    }

    var allGranted: Bool {
        PermissionKind.allCases.allSatisfy { status(for: $0) == .granted }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)

                Text("Welcome to Ora")
                    .font(.title.bold())

                Text("Grant the following permissions to get started.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 36)
            .padding(.bottom, 28)

            // Permission cards
            VStack(spacing: 16) {
                ForEach(Self.permissionDefinitions) { item in
                    permissionCard(item: item, status: status(for: item.kind))
                }
            }
            .padding(.horizontal, 28)

            Spacer()

            // Footer
            HStack {
                Text("You can change these later in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Spacer()

                if allGranted {
                    Button("Get Started") {
                        onComplete?()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button("Skip for Now") {
                        onComplete?()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        }
        .onAppear { realPermissions?.startMonitoring() }
        .onDisappear { realPermissions?.stopMonitoring() }
    }

    // MARK: - Permission Card

    private func permissionCard(item: PermissionItem, status: PermissionStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title row
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 24, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.headline)

                    switch status {
                    case .granted:
                        Text("Permission granted. You're all set.")
                            .font(.caption)
                            .foregroundStyle(.green)
                    case .denied:
                        Text("Permission denied. Please enable it in System Settings.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    case .notRequested:
                        Text(item.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                statusButton(for: item, status: status)
            }

            if status != .granted {
                Divider()

                if status == .denied {
                    Label(
                        "Go to System Settings → Privacy & Security to enable this permission.",
                        systemImage: "arrow.right.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(item.steps.enumerated()), id: \.offset) {
                            stepIndex, step in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(stepIndex + 1).")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 16, alignment: .trailing)

                                Text(step)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.leading, 4)
                }
            }
        }
        .padding(16)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
        .animation(Self.standardAnimation, value: status)
    }

    // MARK: - Status Button

    @ViewBuilder
    private func statusButton(for item: PermissionItem, status: PermissionStatus) -> some View {
        switch status {
        case .notRequested:
            Button("Grant Access") {
                requestPermission(kind: item.kind)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

        case .granted:
            Label("Granted", systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.green)

        case .denied:
            Button("Open Settings") {
                openSettings(kind: item.kind)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Permission Actions

    private func requestPermission(kind: PermissionKind) {
        guard let realPermissions else {
            // Mock mode for previews: flip to granted so the footer
            // button flow is still exercisable.
            withAnimation(Self.standardAnimation) {
                mockStatuses[kind] = .granted
            }
            return
        }

        switch kind {
        case .microphone:
            Task { await realPermissions.requestMicrophone() }
        case .accessibility:
            realPermissions.requestAccessibility()
        }
    }

    private func openSettings(kind: PermissionKind) {
        guard let realPermissions else { return }
        switch kind {
        case .microphone:
            realPermissions.openMicrophoneSettings()
        case .accessibility:
            realPermissions.openAccessibilitySettings()
        }
    }
}

#Preview {
    GetStartedView()
        .frame(width: 540, height: 600)
}
