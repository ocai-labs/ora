//
//  UpdateController.swift
//  ora
//
//  Thin wrapper around Sparkle's SPUStandardUpdaterController. Owns the
//  updater instance for the app's lifetime, exposes `checkForUpdates()`
//  for the "Check for Updates…" button in GeneralPage, and publishes
//  `canCheckForUpdates` so the button can disable itself while Sparkle
//  is already busy.
//
//  We use the *standard* user driver on purpose — it ships Sparkle's
//  built-in update window (release notes, progress, install/relaunch)
//  with zero custom UI code.
//

import Combine
import Foundation
import Sparkle
import SwiftUI

@MainActor
final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    @Published private(set) var canCheckForUpdates: Bool = false

    private let controller: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?

    private init() {
        // `startingUpdater: true` kicks off Sparkle's background scheduler
        // (automatic checks respect `SUEnableAutomaticChecks` in Info.plist).
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        canCheckForUpdates = controller.updater.canCheckForUpdates
        observation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.new]
        ) { [weak self] _, change in
            guard let newValue = change.newValue else { return }
            Task { @MainActor in
                self?.canCheckForUpdates = newValue
            }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
