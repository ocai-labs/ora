//
//  MenuBarView.swift
//  ora
//
//  Menu bar dropdown — native NSMenu style.
//  Hosted by a MenuBarExtra(.menu) so each Button/Menu/Divider here
//  becomes a real NSMenuItem rather than a custom popover row.
//

import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Settings pages — sourced from SettingsPage.allCases so the
        // sidebar and menu stay in sync automatically.
        ForEach(SettingsPage.allCases) { page in
            Button {
                // Set the navigator BEFORE openWindow so ContentView's
                // .onAppear/.onChange picks it up on the way up. This
                // is the same race-free pattern OnboardingWindowContent
                // uses — see SettingsNavigator's header for the why.
                SettingsNavigator.shared.pendingPage = page
                openWindow(id: "settings")
                // Ora is an LSUIElement agent, so `openWindow` alone
                // will surface the window behind whatever app is
                // currently frontmost. Explicitly activate the app and
                // bring the Settings window forward so the user
                // actually sees it. Matched on NSWindow.identifier —
                // SwiftUI encodes the scene id into it — because the
                // window *title* changes to the selected page's
                // navigationTitle after the first navigation, which
                // silently broke a title-based lookup.
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: {
                    $0.identifier?.rawValue.hasPrefix("settings") == true
                }) {
                    window.makeKeyAndOrderFront(nil)
                }
            } label: {
                Label(page.title, systemImage: page.icon)
            }
        }

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
