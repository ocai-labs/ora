//
//  GeneralPage.swift
//  ora
//
//  General settings page — app behavior (Dock, status bar, login item)
//  and Sparkle-backed "Check for Updates…". Appearance and the
//  dictation overlay live on the Interface page.
//

import SwiftUI

struct GeneralPage: View {
    @Environment(Preferences.self) private var preferences
    // ObservedObject, not StateObject: the view must not take
    // ownership of an externally-owned singleton (StateObject only
    // worked here by accident, because the singleton never deallocs).
    @ObservedObject private var updateController = UpdateController.shared

    var body: some View {
        @Bindable var preferences = preferences
        // Safety rail: don't let the user hide both the dock icon and the
        // status bar item at the same time, or the app becomes unreachable.
        let dockToggleLocked = preferences.showInDock && !preferences.showInStatusBar
        let statusToggleLocked = preferences.showInStatusBar && !preferences.showInDock
        return Form {
            Section("Behavior") {
                Toggle("Show in Dock", isOn: $preferences.showInDock)
                    .disabled(dockToggleLocked)

                Toggle("Show in status bar", isOn: $preferences.showInStatusBar)
                    .disabled(statusToggleLocked)

                Toggle("Launch at login", isOn: $preferences.launchAtLogin)
            }

            Section("Other") {
                LabeledContent("Updates") {
                    Button("Check for Updates…") {
                        updateController.checkForUpdates()
                    }
                    .disabled(!updateController.canCheckForUpdates)
                }
                LabeledContent("Installed", value: versionString)
            }
        }
        .formStyle(.grouped)
    }

    private var versionString: String {
        #if DEBUG
        return "\(BuildInfo.marketingVersion)-dev (\(BuildInfo.gitCommitHash))"
        #else
        return "\(BuildInfo.marketingVersion) (\(BuildInfo.gitCommitHash))"
        #endif
    }
}

#Preview {
    GeneralPage()
        .environment(Preferences.shared)
        .frame(width: 500, height: 400)
}
