//
//  EscapeKeyMonitor.swift
//  ora
//
//  Scoped CGEventTap that watches for the Escape key while a
//  dictation overlay is visible, and consumes the event so it does
//  not reach the focused app. Enabled/disabled by DictationCoordinator
//  on state transitions into / out of .recording and .transcribing.
//
//  ## Why a dedicated tap
//
//  HotkeyService taps .flagsChanged — modifier-only keys. Escape is a
//  regular keydown. NSEvent.addLocalMonitorForEvents is not an option
//  either: Ora's overlay is a nonactivating NSPanel, so the app never
//  holds keyboard focus when the overlay is up.
//
//  ## Permissions
//
//  Reuses the Accessibility permission already granted for Paster and
//  HotkeyService. CGEvent.tapCreate returns nil if the grant is missing
//  or revoked; we log and silently no-op (the overlay hover-cancel
//  path still works).
//

@preconcurrency import CoreGraphics
import Foundation

@MainActor
final class EscapeKeyMonitor {
    /// Fired on each Escape keydown while the monitor is enabled.
    var onEscape: (() -> Void)?

    private var tapThread: Thread?
    nonisolated(unsafe) private var runLoopRef: CFRunLoop?
    private var machPort: CFMachPort?

    /// Escape key virtual keycode (kVK_Escape).
    private static let escapeKeyCode: CGKeyCode = 53

    // deinit is nonisolated on @MainActor classes, so we call the
    // teardown primitives directly (CFRunLoopStop / CFMachPortInvalidate
    // are thread-safe). Order matches disable() — invalidate the port
    // first so the run loop source is gone before we ask the run loop
    // itself to stop; this covers the narrow startup-race window where
    // `runLoopRef` hasn't been assigned yet. The HandlerBox is owned
    // and released by the tap thread when its run loop exits —
    // releasing it here would race an in-flight tap callback.
    deinit {
        if let port = machPort {
            CFMachPortInvalidate(port)
        }
        if let rl = runLoopRef {
            CFRunLoopStop(rl)
        }
    }

    // MARK: - Lifecycle

    /// Starts the event tap. No-op if already running.
    func enable() {
        guard machPort == nil else { return }
        startEventTap()
    }

    /// Stops the event tap, letting Escape flow to the focused app
    /// again. No-op if not running. The HandlerBox is released by the
    /// tap thread once its run loop exits — see startEventTap.
    func disable() {
        if let port = machPort {
            CFMachPortInvalidate(port)
            machPort = nil
        }
        if let rl = runLoopRef {
            CFRunLoopStop(rl)
            runLoopRef = nil
        }
        tapThread = nil
    }

    // MARK: - Event tap

    private func startEventTap() {
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue

        let box = Unmanaged.passRetained(
            HandlerBox { [weak self] event in
                self?.handleKeyDown(event)
            }
        )
        let ptr = box.toOpaque()

        // .defaultTap (not .listenOnly) so the returned nil consumes
        // the event — keeps Escape from also dismissing menus, text
        // field edits, etc. in the focused app while we're recording.
        let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                // userInfo is always non-nil while the tap is alive;
                // the guard is a safety net, not a real branch.
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let box = Unmanaged<HandlerBox>.fromOpaque(userInfo).takeUnretainedValue()
                // .defaultTap is subject to macOS's callback-timeout
                // killswitch, even more so than the listen-only tap in
                // HotkeyService. Re-enable using the stashed port. See
                // HotkeyService.swift header for the full rationale.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let portToReenable = box.machPort {
                        CGEvent.tapEnable(tap: portToReenable, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
                if keyCode == EscapeKeyMonitor.escapeKeyCode {
                    box.handler(event)
                    return nil   // consume
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: ptr
        )

        guard let port else {
            print("[EscapeKeyMonitor] CGEvent.tapCreate failed — Accessibility permission may be missing")
            box.release()
            return
        }
        machPort = port
        // Stash the port on the box for the disabled-by-timeout
        // recovery path in the C callback. Set before the run loop
        // source starts firing.
        box.takeUnretainedValue().machPort = port

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)

        // Ownership of the retained HandlerBox transfers to the tap
        // thread: it releases the box only after CFRunLoopRun returns,
        // which cannot happen while the tap callback is mid-execution.
        // Releasing from the main thread (disable/deinit) raced an
        // in-flight callback's takeUnretainedValue — a use-after-free.
        let thread = Thread { [weak self] in
            defer { box.release() }
            guard let source else { return }
            let runLoop = CFRunLoopGetCurrent()
            self?.runLoopRef = runLoop
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "com.ora.escape-eventtap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
    }

    // MARK: - Event handling (called on background thread)

    private nonisolated func handleKeyDown(_ event: CGEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.onEscape?()
        }
    }
}

// MARK: - HandlerBox

// Identical to the HandlerBox in HotkeyService.swift — see that file's
// note. With only two event-tap wrappers in the project, extracting a
// shared helper isn't worth the indirection; if a third ever lands,
// revisit.
private final class HandlerBox: @unchecked Sendable {
    let handler: (CGEvent) -> Void
    var machPort: CFMachPort?
    init(_ handler: @escaping (CGEvent) -> Void) {
        self.handler = handler
    }
}
