//
//  HotkeyService.swift
//  ora
//
//  Global modifier-only hotkey detection using a CGEventTap watching
//  `.flagsChanged` events. Replaces the previous Carbon
//  `RegisterEventHotKey` approach, which cannot handle modifier-only
//  keys (no virtual keycode to register).
//
//  ## How it works
//
//  A CGEventTap in `.listenOnly` mode watches `flagsChanged` events
//  at the session level. Each event carries the keycode of the
//  physical key that changed and the updated modifier flags. We
//  compare the keycode against the registered `ActivationKey.keyCode`
//  and determine press vs release by checking whether the key's
//  `modifierFlag` is present in the event's flags.
//
//  ## Threading
//
//  The event tap callback fires on a dedicated background thread
//  (same pattern as WhisperIsland's EventMonitor). Press/release
//  callbacks are dispatched to the main actor via
//  `DispatchQueue.main.async` so callers don't need to worry about
//  thread safety.
//
//  ## Permissions
//
//  CGEventTap requires the Accessibility permission (TCC). Ora
//  already requests this for Paster, so no new prompt is needed.
//  If the permission is revoked while the app is running, tapCreate
//  returns nil and we log the failure.
//
//  ## Tap disabled-by-timeout
//
//  macOS will disable any `.defaultTap` or `.listenOnly` event tap
//  whose callback runs too long, or after certain system events
//  (sleep/wake, kill-switch). The tap delivers a synthetic event of
//  type `.tapDisabledByTimeout` or `.tapDisabledByUserInput` and then
//  stops firing. Without an explicit re-enable, the hotkey silently
//  dies — which over multi-day runs is one of the ways "Ora stops
//  responding to my shortcut" happens. The C callback below detects
//  both event types and calls `CGEvent.tapEnable` to bring the tap
//  back; see the matching code in EscapeKeyMonitor.
//

@preconcurrency import CoreGraphics
import Foundation

@MainActor
final class HotkeyService {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var registeredKey: ActivationKey?
    private var tapThread: Thread?
    nonisolated(unsafe) private var runLoopRef: CFRunLoop?
    private var machPort: CFMachPort?

    /// Tracks whether the registered key is currently held down.
    /// Thread-safe because all reads and writes happen on the main
    /// thread: the background tap callback extracts keyCode + flags,
    /// then dispatches to `DispatchQueue.main.async` where
    /// `processFlagsChanged` reads/writes `isPressed` and
    /// `registeredKey`.
    private var isPressed = false

    deinit {
        // deinit is nonisolated on @MainActor classes, so we stop
        // the run loop directly (CFRunLoopStop is thread-safe). The
        // HandlerBox is owned and released by the tap thread once its
        // run loop exits — releasing it here would race an in-flight
        // tap callback.
        if let port = machPort {
            CFMachPortInvalidate(port)
        }
        if let rl = runLoopRef {
            CFRunLoopStop(rl)
        }
    }

    // MARK: - Registration

    /// Registers (or re-registers) the modifier-only hotkey.
    /// Starts the CGEventTap if it isn't already running, or
    /// simply swaps the target key if it is.
    ///
    /// Gates on `machPort == nil` rather than "was a key registered":
    /// `tapCreate` can fail transiently (Accessibility races at
    /// launch), and a re-register must retry tap creation in that case
    /// instead of leaving the hotkey permanently dead.
    func register(_ key: ActivationKey) {
        registeredKey = key
        isPressed = false

        if machPort == nil {
            startEventTap()
        }
    }

    // MARK: - Event tap lifecycle

    private func startEventTap() {
        let mask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue

        // The handler closure is passed as a C function pointer via
        // the HandlerBox pattern (same as WhisperIsland's EventMonitor).
        let box = Unmanaged.passRetained(
            HandlerBox { [weak self] event in
                self?.handleFlagsChanged(event)
            }
        )
        let ptr = box.toOpaque()

        let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let box = Unmanaged<HandlerBox>.fromOpaque(userInfo).takeUnretainedValue()
                // macOS disables the tap when its callback runs too long
                // or after certain system events. Re-enable using the
                // port that the HotkeyService stashed on the box after
                // tapCreate succeeded — see file header.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let portToReenable = box.machPort {
                        CGEvent.tapEnable(tap: portToReenable, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                box.handler(event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: ptr
        )

        guard let port else {
            print("[Hotkey] CGEvent.tapCreate failed — Accessibility permission may be missing")
            box.release()
            return
        }
        machPort = port
        // Stash the port on the box so the C callback can re-enable the
        // tap when macOS disables it. Set BEFORE adding the source to a
        // run loop, so the callback never sees a nil port.
        box.takeUnretainedValue().machPort = port

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)

        // Ownership of the retained HandlerBox transfers to the tap
        // thread: it releases the box only after CFRunLoopRun returns,
        // which cannot happen while the tap callback is mid-execution.
        // Releasing from the main thread (deinit/stop) raced an
        // in-flight callback's takeUnretainedValue — a use-after-free.
        let thread = Thread { [weak self] in
            defer { box.release() }
            guard let source else { return }
            let runLoop = CFRunLoopGetCurrent()
            self?.runLoopRef = runLoop
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "com.ora.hotkey-eventtap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
    }

    private func stopEventTap() {
        // Invalidate the port first — this removes the run loop
        // source, causing CFRunLoopRun to exit even if runLoopRef
        // hasn't been assigned yet (narrow race on startup). The tap
        // thread releases the HandlerBox when its run loop exits.
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

    // MARK: - Event handling (called on background thread)

    /// Called from the CGEventTap callback on the background thread.
    /// Dispatches press/release to main.
    private nonisolated func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        DispatchQueue.main.async { [weak self] in
            self?.processFlagsChanged(keyCode: keyCode, flags: flags)
        }
    }

    /// Runs on main. Compares the event's keycode against the
    /// registered key and fires press/release callbacks.
    private func processFlagsChanged(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let registeredKey else { return }
        guard let edge = Self.keyEdge(
            wasPressed: isPressed,
            eventKeyCode: keyCode,
            flags: flags,
            registered: registeredKey
        ) else { return }

        switch edge {
        case .press:
            isPressed = true
            onPress?()
        case .release:
            isPressed = false
            onRelease?()
        }
    }

    // MARK: - Edge detection (pure)

    /// Press/release edge inferred from one flagsChanged event. Pure —
    /// extracted so the decision table is unit-testable without a live
    /// event tap.
    enum KeyEdge: Equatable {
        case press
        case release
    }

    static func keyEdge(
        wasPressed: Bool,
        eventKeyCode: CGKeyCode,
        flags: CGEventFlags,
        registered: ActivationKey
    ) -> KeyEdge? {
        guard eventKeyCode == registered.keyCode else { return nil }

        let isDown = isRegisteredKeyDown(flags: flags, registered: registered)

        if isDown && !wasPressed { return .press }
        if !isDown && wasPressed { return .release }
        return nil
    }

    /// Whether the registered key is held according to this event's
    /// flags. The family flag (`.maskShift` etc.) being clear means
    /// definitely up. When it's set, the device-specific bits decide:
    /// holding left-Shift while releasing a registered right-Shift
    /// keeps `.maskShift` alive, which used to make the release
    /// invisible (recording stuck until the next full press/release).
    /// Events with no device bits for the family — synthetic input,
    /// some remapping tools — fall back to the family answer.
    static func isRegisteredKeyDown(flags: CGEventFlags, registered: ActivationKey) -> Bool {
        guard flags.contains(registered.modifierFlag) else { return false }
        guard let ownBit = registered.deviceSpecificFlagMask,
              let familyBits = registered.familyDeviceFlagMask,
              flags.rawValue & familyBits != 0
        else { return true }
        return flags.rawValue & ownBit != 0
    }
}

// MARK: - HandlerBox

/// Reference-type wrapper so we can pass a Swift closure through
/// the C function pointer callback via `Unmanaged`.
///
/// `machPort` is set once after `CGEvent.tapCreate` succeeds and read
/// from the C callback on the background tap thread to re-enable the
/// tap if macOS disables it. The single-writer-then-many-readers
/// pattern is safe without a lock; @unchecked Sendable acknowledges
/// that we've reasoned about it manually.
private final class HandlerBox: @unchecked Sendable {
    let handler: (CGEvent) -> Void
    var machPort: CFMachPort?
    init(_ handler: @escaping (CGEvent) -> Void) {
        self.handler = handler
    }
}
