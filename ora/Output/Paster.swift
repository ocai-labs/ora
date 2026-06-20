//
//  Paster.swift
//  ora
//
//  Inserts a string at the cursor of the frontmost application by
//  hijacking the general pasteboard, synthesizing Cmd+V, then restoring
//  the user's previous pasteboard contents. This is the same recipe
//  every mainstream macOS dictation tool uses — direct Accessibility
//  text insertion (AXUIElement + kAXValueAttribute) works in some apps
//  but fails in browsers, Electron, and games, whereas the synthetic
//  paste path reaches anywhere a human can paste manually.
//
//  ## Required permissions
//
//  Posting synthetic keyboard events through `CGEvent.post(tap:)`
//  requires the app to be granted **Accessibility** access in System
//  Settings ▸ Privacy & Security ▸ Accessibility. Without it,
//  `CGEvent.post` silently succeeds but no event is delivered, so the
//  user would see no paste and no error. We expose `isTrusted` and
//  `requestTrust(prompt:)` so the caller can surface a clear failure
//  before attempting the paste rather than appearing to paste into the
//  void.
//
//  ## Why a delay before restoring the pasteboard
//
//  Apps read the pasteboard asynchronously *after* Cmd+V is delivered.
//  If we restore the previous contents immediately the fast paths in
//  Chrome / Slack / VS Code will see the restored value and paste the
//  wrong thing. A short sleep (~150 ms) is enough on every app I've
//  measured. The cost is paid only on the dictation tail, after the
//  user already sees their text appear, so it's invisible in practice.
//
//  ## Snapshot fidelity
//
//  We snapshot every `(type, data)` pair currently on the pasteboard
//  and put them all back after the paste. That preserves rich content
//  the user had on the clipboard — RTF, file URLs, images — not just
//  the plain-text flavor. The transcript itself is set as `.string`
//  only, since that's what every paste target expects.
//

import AppKit
import ApplicationServices

@MainActor
final class Paster {
    enum Failure: Error, LocalizedError {
        case accessibilityNotTrusted
        case eventCreationFailed

        var errorDescription: String? {
            switch self {
            case .accessibilityNotTrusted:
                return "Ora needs Accessibility access to paste. Open System Settings ▸ Privacy & Security ▸ Accessibility and enable Ora."
            case .eventCreationFailed:
                return "Failed to construct synthetic key events for Cmd+V."
            }
        }
    }

    /// Whether this process is currently trusted by the Accessibility
    /// subsystem. Cheap and silent — no prompt is shown.
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Same trust check, but with the option to surface the system
    /// prompt that adds Ora to the Accessibility list. The prompt is
    /// only shown if we're not already trusted; subsequent calls with
    /// `prompt: true` are no-ops once trust has been granted.
    @discardableResult
    static func requestTrust(prompt: Bool = true) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: NSDictionary = [key: prompt]
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Pastes `text` into the frontmost application:
    ///   1. Snapshot the current pasteboard.
    ///   2. Replace its contents with `text`.
    ///   3. Post a synthetic Cmd+V into the HID event stream.
    ///   4. Wait briefly for the target app to consume it.
    ///   5. Restore the snapshotted pasteboard.
    ///
    /// Throws `.accessibilityNotTrusted` if the user hasn't granted
    /// Accessibility access — the synthetic Cmd+V would silently fail
    /// otherwise, so we'd rather surface that as a real error.
    func paste(_ text: String) async throws {
        guard Self.isTrusted else { throw Failure.accessibilityNotTrusted }

        // Wait for the activation modifier to be released before we
        // synthesize Cmd+V. In toggle mode the stop+transcribe is
        // triggered on the activation key's key-DOWN, so that modifier
        // is usually still physically held when we reach here. Posting
        // Cmd+V while it's held merges the held flag into the event (the
        // source uses .combinedSessionState) so the keystroke doesn't
        // register as a clean paste until the user lets go — and by then
        // the 150 ms restore below has already put the previous clipboard
        // back, so the target pastes THAT (the user's last copy) instead
        // of the transcript. Hold mode releases the key before
        // transcription even starts, so this returns immediately and the
        // path is unchanged. Best-effort: capped by a timeout so a stuck
        // flag can't wedge the paste, and run *before* we hijack the
        // pasteboard so an ESC-cancel mid-wait aborts without ever
        // touching the user's clipboard.
        try await Self.waitForModifiersToClear()

        let pasteboard = NSPasteboard.general
        let snapshot = Self.snapshotPasteboard(pasteboard)

        // `clearContents` + `setString` bumps the changeCount, which is
        // what apps watch to know "new clipboard available". We declare
        // only `.string` for the dictation flavor — preserving rich
        // multi-flavor output for the transcript itself isn't useful.
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // changeCount after our write: if someone else (the user, a
        // clipboard manager) writes the pasteboard during the wait
        // below, the count moves past this and we must not clobber
        // their content with our stale snapshot.
        let ourChangeCount = pasteboard.changeCount

        do {
            try Self.postCommandV()
        } catch {
            // No Cmd+V was delivered, so nothing will read the
            // transcript — put the user's clipboard back rather than
            // leaving it hijacked.
            Self.restorePasteboard(pasteboard, from: snapshot, ifChangeCountIs: ourChangeCount)
            throw error
        }

        // Give the target app time to actually read the pasteboard
        // before we put the user's old contents back. 150 ms is the
        // smallest value I've measured that survives Chrome and Slack
        // on an idle machine; bump if you find an app that loses text.
        //
        // Detached so a coordinator cancel() during this window can't
        // turn the sleep into an immediate return — restoring 0 ms
        // after the Cmd+V means the target app reads the *restored*
        // clipboard and pastes the wrong thing.
        await Task.detached {
            try? await Task.sleep(for: .milliseconds(150))
        }.value

        Self.restorePasteboard(pasteboard, from: snapshot, ifChangeCountIs: ourChangeCount)
    }

    // MARK: - CGEvent plumbing

    /// Posts a synthetic Cmd+V keydown/keyup pair through the HID event
    /// tap. Uses `combinedSessionState` so the synthetic events ride
    /// alongside real keyboard input rather than competing with it
    /// (which is what happens with `.privateState`).
    private static func postCommandV() throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        // 9 == kVK_ANSI_V (Carbon virtual keycode). Hardcoded so this
        // file doesn't need to drag in Carbon.HIToolbox for one
        // constant. The mapping is fixed across every Mac keyboard.
        let vKey: CGKeyCode = 9
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else {
            throw Failure.eventCreationFailed
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // `.cghidEventTap` injects at the same point a real keystroke
        // enters the system, so the event reaches every app — including
        // those with custom event handling that ignore higher taps.
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Held-modifier gate

    /// Modifier flags that, if physically held the instant we synthesize
    /// Cmd+V, merge into the event and stop it from registering as a
    /// clean paste — the keystroke is effectively deferred until the user
    /// releases the key. Caps Lock (`.maskAlphaShift`) and numeric/
    /// secondary state are deliberately excluded: they don't corrupt a
    /// Cmd+V. Every `ActivationKey` is one of these, which is why toggle
    /// mode (stop on key-DOWN) reaches the paste with the key still held.
    static let interferingFlags: CGEventFlags =
        [.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]

    /// Pure predicate: does this flag set contain a modifier that would
    /// corrupt a synthetic Cmd+V? Extracted so the gate's logic is
    /// unit-testable without live hardware state.
    static func hasInterferingModifier(_ flags: CGEventFlags) -> Bool {
        !flags.intersection(interferingFlags).isEmpty
    }

    /// Suspends until no interfering modifier is physically held, polling
    /// the live hardware state, or until `timeout` elapses (best-effort —
    /// we'd rather paste against a stuck flag than drop the transcript).
    /// Throws `CancellationError` if the dictation is cancelled mid-wait,
    /// which aborts `paste` before it touches the pasteboard.
    private static func waitForModifiersToClear(
        timeout: Duration = .seconds(2),
        poll: Duration = .milliseconds(15)
    ) async throws {
        var waited: Duration = .zero
        while hasInterferingModifier(CGEventSource.flagsState(.combinedSessionState)),
              waited < timeout {
            try await Task.sleep(for: poll)
            waited += poll
        }
    }

    // MARK: - Pasteboard snapshot / restore

    /// Captures every `(type, data)` pair currently on the pasteboard
    /// so we can put them back verbatim. Order is preserved because
    /// some pasting apps prefer the first declared type.
    // Internal (not private) so the snapshot/restore contract can be
    // unit-tested against a uniquely-named test pasteboard.
    static func snapshotPasteboard(
        _ pb: NSPasteboard
    ) -> [(NSPasteboard.PasteboardType, Data)] {
        guard let types = pb.types else { return [] }
        return types.compactMap { type in
            guard let data = pb.data(forType: type) else { return nil }
            return (type, data)
        }
    }

    /// Restores the snapshot only when the pasteboard still holds our
    /// transcript (`changeCount` unchanged since our write). If another
    /// writer got there first, their content wins — restoring would
    /// silently destroy whatever the user just copied.
    static func restorePasteboard(
        _ pb: NSPasteboard,
        from snapshot: [(NSPasteboard.PasteboardType, Data)],
        ifChangeCountIs expectedChangeCount: Int
    ) {
        guard pb.changeCount == expectedChangeCount else { return }
        pb.clearContents()
        guard !snapshot.isEmpty else { return }
        pb.declareTypes(snapshot.map(\.0), owner: nil)
        for (type, data) in snapshot {
            pb.setData(data, forType: type)
        }
    }
}
