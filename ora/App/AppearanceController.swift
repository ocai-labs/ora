//
//  AppearanceController.swift
//  ora
//
//  Applies system-level side effects for General settings:
//  dock icon visibility and login-item registration.
//
//  The status-bar visibility is driven directly by SwiftUI via the
//  MenuBarExtra `isInserted:` binding, so it has no business here.
//

import AppKit
import ServiceManagement

enum AppearanceController {
    /// Applies every system-level preference that has a side effect.
    /// Safe to call from any thread; hops to main for AppKit calls.
    static func apply(_ preferences: Preferences) {
        applyDockVisibility(preferences.showInDock)
        applyLaunchAtLogin(preferences.launchAtLogin)
        applyAppearance(preferences.appearance)
    }

    static func applyDockVisibility(_ visible: Bool) {
        let policy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        // Use NSApplication.shared (non-optional) rather than NSApp (IUO global
        // that is nil until the shared instance is first touched). This lets
        // us safely call it from App.init() before SwiftUI has created NSApp.
        let work = {
            let app = NSApplication.shared
            // Only run the policy change + re-activation dance when the
            // policy actually changes. apply() runs unconditionally at
            // every launch, and activate(ignoringOtherApps:) would
            // steal focus from whatever the user is working in — bad
            // for a background agent that starts at login.
            guard app.activationPolicy() != policy else { return }
            let wasActive = app.isActive
            app.setActivationPolicy(policy)
            // Transitioning .regular -> .accessory deactivates the app, which
            // would let other apps' windows steal the front. Re-activate and
            // raise whatever window was frontmost so the Settings window stays
            // visible and focused across the toggle. Skip when the app wasn't
            // active to begin with (launch-time apply) — there's nothing to
            // preserve and the activation would steal the user's focus.
            guard wasActive else { return }
            app.activate(ignoringOtherApps: true)
            if let front = app.keyWindow ?? app.windows.first(where: { $0.isVisible }) {
                front.orderFrontRegardless()
            }
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async { work() }
        }
    }

    /// Applies the user's chosen appearance to the whole AppKit app.
    /// `.system` clears the override so the OS theme drives it.
    static func applyAppearance(_ mode: AppearanceMode) {
        let appearance: NSAppearance?
        switch mode {
        case .system:
            appearance = nil
        case .light:
            appearance = NSAppearance(named: .aqua)
        case .dark:
            appearance = NSAppearance(named: .darkAqua)
        }
        let work = { NSApplication.shared.appearance = appearance }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async { work() }
        }
    }

    /// Registers or unregisters the app as a login item via ServiceManagement.
    /// Silently no-ops if the underlying call throws — the UI state is
    /// persisted independently, so a transient failure should not corrupt it.
    static func applyLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            switch (enabled, service.status) {
            case (true, .enabled):
                return
            case (true, _):
                try service.register()
            case (false, .notRegistered), (false, .notFound):
                return
            case (false, _):
                try service.unregister()
            }
        } catch {
            NSLog("ora: failed to \(enabled ? "register" : "unregister") login item: \(error)")
        }
    }
}
