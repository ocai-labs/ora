//
//  oraApp.swift
//  ora
//
//  Created by Kristamps Wang on 4/8/26.
//

import AppKit
import SwiftUI

@main
struct oraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var preferences = Preferences.shared
    @State private var modelManager = ModelManager.shared
    @State private var history = HistoryStore.shared

    var body: some Scene {
        MenuBarExtra(
            isInserted: Binding(
                get: { preferences.showInStatusBar },
                set: { preferences.showInStatusBar = $0 }
            )
        ) {
            MenuBarView()
                .environment(preferences)
                .environment(modelManager)
                .environment(DictationCoordinator.shared.inputDevices)
        } label: {
            MenuBarIcon(permissions: appDelegate.permissions)
        }
        .menuBarExtraStyle(.menu)

        Window("Settings", id: "settings") {
            ContentView()
                .environment(preferences)
                .environment(modelManager)
                .environment(history)
                .environment(DictationCoordinator.shared.inputDevices)
                .onChange(of: preferences.showInDock) { _, newValue in
                    AppearanceController.applyDockVisibility(newValue)
                }
                .onChange(of: preferences.launchAtLogin) { _, newValue in
                    AppearanceController.applyLaunchAtLogin(newValue)
                }
                .onChange(of: preferences.appearance) { _, newValue in
                    AppearanceController.applyAppearance(newValue)
                }
        }
        .windowResizability(.contentSize)

        Window("Get Started", id: "onboarding") {
            OnboardingWindowContent(permissions: appDelegate.permissions)
                .frame(width: 520, height: 520)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}

/// Menu-bar-first app delegate.
///
/// `INFOPLIST_KEY_LSUIElement = YES` in the target's build settings is
/// what guarantees no dock icon at launch — with that flag the app
/// launches as an agent. This delegate then reads the user's
/// `Show in Dock` preference and promotes the activation policy if
/// they've opted in. It also owns the shared `Permissions` observable
/// that the onboarding window and menu-bar icon both read.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Shared permission observable. Owned here so the onboarding
    /// window and launch-time `MenuBarIcon.task` see the same
    /// instance. The dictation pipeline does NOT use this — it still
    /// reads `MicrophonePermission.status` and `Paster.isTrusted`
    /// directly at hotkey time. See the onboarding wire-up design doc
    /// for why the two sources are not unified yet.
    let permissions = Permissions()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearanceController.apply(Preferences.shared)
        DictationCoordinator.shared.start()
        // Touch UpdateController.shared so its init runs, which starts
        // Sparkle's background update scheduler.
        _ = UpdateController.shared
    }

    /// Don't quit when the last window closes — we live in the menu bar,
    /// and closing the Settings window should hide it, not kill the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// If the user clicks the Dock icon (when `showInDock` is enabled)
    /// and no windows are visible, bring any existing windows forward
    /// rather than opening the default one. Mirrors whisper.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // Only resurface windows the user had previously made
            // visible — SwiftUI keeps scene-backing windows alive
            // after dismissal, and we don't want to re-show a
            // dismissed onboarding window from a Dock-icon click.
            for window in sender.windows where window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }
            sender.activate()
        }
        return true
    }
}

// MARK: - MenuBarIcon

/// Hosts the menu-bar label image AND the launch-time "should we open
/// onboarding?" decision. Kept as its own view so that permission
/// observation doesn't force `oraApp.body` to re-evaluate — re-diffing
/// the scene graph when permissions change is both wasteful and known
/// to trigger SwiftUI Window-scene edge cases.
private struct MenuBarIcon: View {
    let permissions: Permissions
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image("MenuBarIcon")
            .accessibilityLabel("Ora")
            .task {
                let shouldShow = !Preferences.shared.hasCompletedOnboarding
                    || !permissions.allPermissionsGranted
                if shouldShow {
                    openWindow(id: "onboarding")
                }
            }
    }
}

// MARK: - OnboardingWindowContent

/// Wrapper that owns the `@Environment(\.dismiss)` +
/// `@Environment(\.openWindow)` bindings for the onboarding window and
/// runs the "did we finish?" side effects.
private struct OnboardingWindowContent: View {
    let permissions: Permissions
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        GetStartedView(
            permissions: permissions,
            onComplete: {
                Preferences.shared.hasCompletedOnboarding = true

                let selectedId = Preferences.shared.selectedModelId ?? Preferences.defaultModelId
                if !ModelManager.shared.isInstalled(selectedId) {
                    // Set the pending page BEFORE openWindow so that
                    // ContentView.onAppear sees it on its way up. The
                    // reverse order races against SwiftUI's window
                    // mount; see SettingsNavigator's header for the
                    // long version.
                    SettingsNavigator.shared.pendingPage = .models
                    openWindow(id: "settings")
                }
                dismiss()
            }
        )
        .onAppear {
            // Promote the onboarding window to floating so it stays on
            // top of System Settings while the user grants permissions.
            // TODO: replace with .windowLevel(.floating) scene modifier
            // once the minimum deployment target is macOS 15.
            // Matched on identifier (scene id), not title — titles are
            // locale- and navigation-dependent; see MenuBarView.
            if let window = NSApp.windows.first(where: {
                $0.identifier?.rawValue.hasPrefix("onboarding") == true
            }) {
                window.level = .floating
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
