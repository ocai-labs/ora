//
//  DictationKeyMonitorTests.swift
//  oraTests
//
//  Locks down DictationKeyMonitor.disposition — the pure decision the
//  event tap makes for every keydown while dictation is active:
//  Escape always cancels; Return / keypad Enter finishes the dictation
//  (and is consumed) only while armed and without extra modifiers;
//  everything else reaches the focused app.
//

import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import ora

struct DictationKeyMonitorTests {
    private typealias Monitor = DictationKeyMonitor

    private static let returnKey = CGKeyCode(kVK_Return)
    private static let keypadEnter = CGKeyCode(kVK_ANSI_KeypadEnter)
    private static let escape = CGKeyCode(kVK_Escape)
    private static let letterA = CGKeyCode(kVK_ANSI_A)

    private static let armedPlain = Monitor.ReturnArming(isArmed: true, allowedModifiers: 0)
    private static func armed(allowing flags: CGEventFlags) -> Monitor.ReturnArming {
        .init(isArmed: true, allowedModifiers: flags.rawValue)
    }

    private func disposition(
        _ key: CGKeyCode,
        flags: CGEventFlags = [],
        autorepeat: Bool = false,
        lastConsumed: Bool = false,
        arming: Monitor.ReturnArming
    ) -> Monitor.Disposition {
        Monitor.disposition(
            keyCode: key, flags: flags, isAutorepeat: autorepeat,
            returnArming: arming, lastReturnConsumed: lastConsumed)
    }

    @Test("keycode literals match Carbon's kVK constants")
    func keycodesMatchCarbon() {
        #expect(Monitor.escapeKeyCode == Self.escape)
        #expect(Monitor.returnKeyCodes == [Self.returnKey, Self.keypadEnter])
    }

    @Test("Escape always cancels, armed or not")
    func escapeAlwaysCancels() {
        #expect(disposition(Self.escape, arming: .disarmed) == .escape)
        #expect(disposition(Self.escape, arming: Self.armedPlain) == .escape)
        #expect(disposition(Self.escape, flags: .maskCommand, arming: .disarmed) == .escape)
    }

    @Test("armed plain Return and keypad Enter finish the dictation")
    func armedReturnFinishes() {
        #expect(disposition(Self.returnKey, arming: Self.armedPlain) == .returnKey)
        #expect(disposition(Self.keypadEnter, arming: Self.armedPlain) == .returnKey)
    }

    @Test("keypad Enter's own numeric-pad flag doesn't disqualify it")
    func keypadFlagIgnored() {
        #expect(disposition(Self.keypadEnter, flags: .maskNumericPad, arming: Self.armedPlain) == .returnKey)
        #expect(disposition(Self.returnKey, flags: .maskAlphaShift, arming: Self.armedPlain) == .returnKey)
    }

    @Test("disarmed Return passes through (e.g. while transcribing)")
    func disarmedReturnPassesThrough() {
        #expect(disposition(Self.returnKey, arming: .disarmed) == .passThrough)
        #expect(disposition(Self.keypadEnter, arming: .disarmed) == .passThrough)
    }

    @Test("Return with a non-allowed modifier is the app's shortcut, not ours")
    func modifiedReturnPassesThrough() {
        for flag: CGEventFlags in [.maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn] {
            #expect(disposition(Self.returnKey, flags: flag, arming: Self.armedPlain) == .passThrough)
        }
    }

    @Test("hold mode: the activation key's own modifier may be held")
    func allowedModifierCounts() {
        let arming = Self.armed(allowing: .maskCommand)
        #expect(disposition(Self.returnKey, flags: .maskCommand, arming: arming) == .returnKey)
        #expect(disposition(Self.returnKey, arming: arming) == .returnKey)
        #expect(disposition(Self.returnKey, flags: [.maskCommand, .maskShift], arming: arming) == .passThrough)
    }

    @Test("repeats of a consumed Return are swallowed without acting, even once disarmed")
    func autorepeatOfConsumedSwallowed() {
        #expect(disposition(Self.returnKey, autorepeat: true, lastConsumed: true, arming: Self.armedPlain) == .swallow)
        // The consumed press disarmed Return (→ .transcribing); its
        // repeats must still not reach the app.
        #expect(disposition(Self.returnKey, autorepeat: true, lastConsumed: true, arming: .disarmed) == .swallow)
    }

    @Test("repeats of a Return the app received pass through (regression: were swallowed)")
    func autorepeatOfPassedThroughPasses() {
        #expect(disposition(Self.returnKey, autorepeat: true, lastConsumed: false, arming: .disarmed) == .passThrough)
        // ⇧↩ held during a toggle-mode recording: the app's newline repeats.
        #expect(disposition(
            Self.returnKey, flags: .maskShift, autorepeat: true, lastConsumed: false,
            arming: Self.armedPlain) == .passThrough)
        // A repeat never finishes the dictation on its own.
        #expect(disposition(Self.returnKey, autorepeat: true, lastConsumed: false, arming: Self.armedPlain) == .passThrough)
    }

    @Test("other keys always pass through")
    func otherKeysPassThrough() {
        #expect(disposition(Self.letterA, arming: Self.armedPlain) == .passThrough)
        #expect(disposition(Self.letterA, autorepeat: true, arming: Self.armedPlain) == .passThrough)
    }
}
