//
//  SettingsNavigator.swift
//  ora
//
//  Tiny shared "which Settings page should be foregrounded next"
//  observable. Used by callers (the menu bar, the onboarding
//  completion path) that want to open the Settings window AND have
//  it land on a specific page.
//
//  Why this exists rather than a NotificationCenter post: the original
//  design used notifications, but SwiftUI's `openWindow` is async — by
//  the time `ContentView.onReceive` subscribes, a synchronous post on
//  the next line has already been delivered to no subscriber. State
//  written *before* `openWindow` survives the window-mount round trip
//  because `ContentView.onAppear` reads it on its way up.
//

import Observation

@MainActor
@Observable
final class SettingsNavigator {
    static let shared = SettingsNavigator()

    /// Page the next Settings-window appearance should jump to.
    /// Consumers (`ContentView`) read this on `onAppear` and clear
    /// it so a subsequent open doesn't re-jump.
    var pendingPage: SettingsPage?

    private init() {}
}
