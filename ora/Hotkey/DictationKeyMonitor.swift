//
//  DictationKeyMonitor.swift
//  ora
//
//  Scoped CGEventTap that watches regular keydowns while a dictation
//  overlay is visible. Enabled/disabled by DictationCoordinator on
//  state transitions into / out of .starting, .recording and
//  .transcribing. (Formerly EscapeKeyMonitor.)
//
//  It handles two keys:
//
//   - Escape → `onEscape` (cancel). Consumed whenever the tap is on.
//   - Return / keypad Enter → `onReturn` (finish the dictation, same
//     as the activation key). Only while *armed* — the coordinator arms
//     it in .starting / .recording and disarms it everywhere else — and
//     then consumed, so a chat app doesn't also send an empty message.
//     Outside that window Return passes through untouched (in
//     particular during .transcribing: we don't swallow a keystroke
//     the user meant for their app).
//
//  ## Why Return
//
//  People coming from ChatGPT-style inputs press Return to "send" a
//  dictation instead of the activation key. Both now work; nothing
//  about the activation-key path changes.
//
//  Return counts only when no modifier is held other than the ones in
//  `allowedReturnModifiers` (the coordinator allows the activation
//  key's own family in hold mode, where it is necessarily held down).
//  ⌘↩ / ⇧↩ etc. otherwise pass through as the app's own shortcuts.
//  Autorepeated Return keydowns follow their initial keydown: if the
//  tap consumed the initial press (it finished the dictation), its
//  repeats are swallowed too, so holding Return can't fire a repeat
//  into the app while the transcription is running; if the initial
//  press passed through, so do its repeats. Known gap: a consumed
//  Return still held after the tap turns off (back at .idle) delivers
//  its remaining repeats to the app — we don't keep a keyboard tap
//  alive outside a dictation just for that.
//
//  ## Why a dedicated tap
//
//  HotkeyService taps .flagsChanged — modifier-only keys. Escape and
//  Return are regular keydowns. NSEvent.addLocalMonitorForEvents is not
//  an option either: Ora's overlay is a nonactivating NSPanel, so the
//  app never holds keyboard focus when the overlay is up.
//
//  ## Threading
//
//  The consume-or-pass decision has to be made synchronously on the
//  tap thread, so the Return arming lives in an unfair lock the tap
//  reads (and updates with each Return press's fate); the callbacks themselves hop to the main queue.
//
//  ## Permissions
//
//  Reuses the Accessibility permission already granted for Paster and
//  HotkeyService. CGEvent.tapCreate returns nil if the grant is missing
//  or revoked; we log and silently no-op (the overlay hover-cancel
//  path and the activation key still work).
//

@preconcurrency import CoreGraphics
import Foundation
import os

@MainActor
final class DictationKeyMonitor {
    /// Fired on each Escape keydown while the monitor is enabled.
    var onEscape: (() -> Void)?

    /// Fired on a plain Return / keypad Enter keydown while the
    /// monitor is enabled AND Return is armed (see `armReturn`).
    var onReturn: (() -> Void)?

    /// What the tap does with a keydown. Pure — see `disposition`.
    nonisolated enum Disposition: Equatable, Sendable {
        case escape        // consume, fire onEscape
        case returnKey     // consume, fire onReturn
        case swallow       // consume, fire nothing
        case passThrough   // deliver to the focused app
    }

    /// Everything the tap thread reads/writes under one lock: the
    /// coordinator-controlled arming, plus whether the most recent
    /// initial Return keydown was consumed (its autorepeats follow it).
    /// `lastReturnConsumed` is deliberately NOT reset by arm/disarm:
    /// the coordinator disarms on the very transition a consumed Return
    /// triggers, and the held key's repeats must stay swallowed.
    nonisolated struct TapState: Sendable {
        var arming: ReturnArming = .disarmed
        var lastReturnConsumed = false
    }

    /// Return-key arming, shared with the tap thread.
    nonisolated struct ReturnArming: Equatable, Sendable {
        var isArmed: Bool
        /// Raw `CGEventFlags` that may be held without disqualifying
        /// the Return press.
        var allowedModifiers: UInt64

        static let disarmed = ReturnArming(isArmed: false, allowedModifiers: 0)
    }

    // Virtual keycodes as literals: importing Carbon here re-exports
    // CoreFoundation without @preconcurrency and trips Sendable checks
    // on the tap thread's run loop source. Values from HIToolbox
    // Events.h; DictationKeyMonitorTests cross-checks them.
    nonisolated static let escapeKeyCode: CGKeyCode = 53          // kVK_Escape
    nonisolated static let returnKeyCodes: Set<CGKeyCode> = [
        36,   // kVK_Return
        76,   // kVK_ANSI_KeypadEnter
    ]

    /// Modifier families that disqualify a Return press unless allowed.
    /// Excludes caps lock and the numeric-pad / help bits that keypad
    /// Enter itself carries.
    nonisolated static let disqualifyingModifiers: CGEventFlags = [
        .maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn,
    ]

    private var tapThread: Thread?
    nonisolated(unsafe) private var runLoopRef: CFRunLoop?
    private var machPort: CFMachPort?
    private let tapState = OSAllocatedUnfairLock(initialState: TapState())

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

    /// Stops the event tap, letting every key flow to the focused app
    /// again, and disarms Return. No-op if not running. The HandlerBox
    /// is released by the tap thread once its run loop exits — see
    /// startEventTap.
    func disable() {
        tapState.withLock { $0 = TapState() }
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

    /// Makes Return finish the dictation (and be consumed) while the
    /// tap is on. `allowedModifiers` may be held during the press.
    func armReturn(allowedModifiers: CGEventFlags) {
        let arming = ReturnArming(isArmed: true, allowedModifiers: allowedModifiers.rawValue)
        tapState.withLock { $0.arming = arming }
    }

    /// Lets Return pass through to the focused app again.
    func disarmReturn() {
        tapState.withLock { $0.arming = .disarmed }
    }

    // MARK: - Decision

    /// What to do with a keydown. Pure — unit-tested in
    /// DictationKeyMonitorTests. `lastReturnConsumed` is whether the
    /// initial keydown of the Return currently held was consumed.
    nonisolated static func disposition(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        isAutorepeat: Bool,
        returnArming: ReturnArming,
        lastReturnConsumed: Bool
    ) -> Disposition {
        if keyCode == escapeKeyCode { return .escape }
        guard returnKeyCodes.contains(keyCode) else { return .passThrough }
        // A repeat never acts. It is swallowed only if we consumed the
        // initial press; a Return the app received keeps repeating
        // normally (disarmed, or ⇧↩ / ⌘↩ shortcuts).
        if isAutorepeat { return lastReturnConsumed ? .swallow : .passThrough }
        guard returnArming.isArmed else { return .passThrough }
        let held = flags.intersection(disqualifyingModifiers)
        let allowed = CGEventFlags(rawValue: returnArming.allowedModifiers)
        guard held.isSubset(of: allowed) else { return .passThrough }
        return .returnKey
    }

    // MARK: - Event tap

    private func startEventTap() {
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue

        let box = Unmanaged.passRetained(
            HandlerBox(tapState: tapState) { [weak self] disposition in
                self?.handle(disposition)
            }
        )
        let ptr = box.toOpaque()

        // .defaultTap (not .listenOnly) so the returned nil consumes
        // the event — keeps Escape from also dismissing menus, text
        // field edits, etc., and Return from sending a chat message,
        // in the focused app while we're recording.
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
                guard type == .keyDown else { return Unmanaged.passUnretained(event) }
                let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
                let flags = event.flags
                let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                let disposition = box.tapState.withLock { state in
                    let d = DictationKeyMonitor.disposition(
                        keyCode: keyCode,
                        flags: flags,
                        isAutorepeat: isAutorepeat,
                        returnArming: state.arming,
                        lastReturnConsumed: state.lastReturnConsumed
                    )
                    // Remember the fate of each initial Return press so
                    // its autorepeats can follow it.
                    if !isAutorepeat, DictationKeyMonitor.returnKeyCodes.contains(keyCode) {
                        state.lastReturnConsumed = (d == .returnKey)
                    }
                    return d
                }
                switch disposition {
                case .escape, .returnKey:
                    box.handler(disposition)
                    return nil   // consume
                case .swallow:
                    return nil   // consume
                case .passThrough:
                    return Unmanaged.passUnretained(event)
                }
            },
            userInfo: ptr
        )

        guard let port else {
            print("[DictationKeyMonitor] CGEvent.tapCreate failed — Accessibility permission may be missing")
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
        thread.name = "com.ora.dictation-key-eventtap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
    }

    // MARK: - Event handling (called on background thread)

    private nonisolated func handle(_ disposition: Disposition) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch disposition {
            case .escape: self.onEscape?()
            case .returnKey: self.onReturn?()
            case .swallow, .passThrough: break
            }
        }
    }
}

// MARK: - HandlerBox

// Same shape as the HandlerBox in HotkeyService.swift — see that
// file's note — plus the Return state the tap reads synchronously.
// With only two event-tap wrappers in the project, extracting a
// shared helper isn't worth the indirection; if a third ever lands,
// revisit.
private final class HandlerBox: @unchecked Sendable {
    let handler: (DictationKeyMonitor.Disposition) -> Void
    let tapState: OSAllocatedUnfairLock<DictationKeyMonitor.TapState>
    var machPort: CFMachPort?
    init(
        tapState: OSAllocatedUnfairLock<DictationKeyMonitor.TapState>,
        _ handler: @escaping (DictationKeyMonitor.Disposition) -> Void
    ) {
        self.tapState = tapState
        self.handler = handler
    }
}
