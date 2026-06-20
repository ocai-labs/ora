//
//  HotkeyEdgeDetectionTests.swift
//  oraTests
//
//  Locks down the pure press/release edge detection extracted from
//  HotkeyService.processFlagsChanged, and carries the known-issue
//  test for review finding #6: the family-mask check can't tell left
//  from right siblings of the same modifier.
//

import CoreGraphics
import Testing
@testable import ora

@MainActor
struct HotkeyEdgeDetectionTests {

    private let key = ActivationKey.rightCommand

    @Test("flag appearing on the registered keycode is a press")
    func pressEdge() {
        let edge = HotkeyService.keyEdge(
            wasPressed: false,
            eventKeyCode: key.keyCode,
            flags: [.maskCommand],
            registered: key
        )
        #expect(edge == .press)
    }

    @Test("flag clearing on the registered keycode is a release")
    func releaseEdge() {
        let edge = HotkeyService.keyEdge(
            wasPressed: true,
            eventKeyCode: key.keyCode,
            flags: [],
            registered: key
        )
        #expect(edge == .release)
    }

    @Test("events for other keycodes are ignored")
    func otherKeycodeIgnored() {
        let edge = HotkeyService.keyEdge(
            wasPressed: false,
            eventKeyCode: ActivationKey.leftShift.keyCode,
            flags: [.maskShift],
            registered: key
        )
        #expect(edge == nil)
    }

    @Test("duplicate down/up events produce no edge")
    func duplicateEventsIgnored() {
        #expect(HotkeyService.keyEdge(
            wasPressed: true,
            eventKeyCode: key.keyCode,
            flags: [.maskCommand],
            registered: key
        ) == nil)
        #expect(HotkeyService.keyEdge(
            wasPressed: false,
            eventKeyCode: key.keyCode,
            flags: [],
            registered: key
        ) == nil)
    }

    @Test("unrelated modifiers held during the event don't mask the edge")
    func unrelatedModifiersDontMask() {
        // Cmd going down while Shift is already held: still a press.
        let edge = HotkeyService.keyEdge(
            wasPressed: false,
            eventKeyCode: key.keyCode,
            flags: [.maskCommand, .maskShift],
            registered: key
        )
        #expect(edge == .press)
    }

    @Test("releasing right-Shift while left-Shift is held is still a release")
    func siblingModifierHeldDuringRelease() {
        // The family flag .maskShift stays set because the left
        // sibling is still down; the device-specific bits are what
        // reveal that the registered right-Shift itself went up
        // (review finding #6 — recording used to stick until the next
        // full press/release cycle).
        let leftShiftBit = ActivationKey.leftShift.deviceSpecificFlagMask!
        let edge = HotkeyService.keyEdge(
            wasPressed: true,
            eventKeyCode: ActivationKey.rightShift.keyCode,
            flags: CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | leftShiftBit),
            registered: .rightShift
        )
        #expect(edge == .release)
    }

    @Test("pressing right-Shift while left-Shift is already held is a press")
    func siblingModifierHeldDuringPress() {
        let leftBit = ActivationKey.leftShift.deviceSpecificFlagMask!
        let rightBit = ActivationKey.rightShift.deviceSpecificFlagMask!
        let edge = HotkeyService.keyEdge(
            wasPressed: false,
            eventKeyCode: ActivationKey.rightShift.keyCode,
            flags: CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | leftBit | rightBit),
            registered: .rightShift
        )
        #expect(edge == .press)
    }

    @Test("the mirror case: releasing left-Shift while right-Shift is held")
    func leftReleasedWhileRightHeld() {
        let rightBit = ActivationKey.rightShift.deviceSpecificFlagMask!
        let edge = HotkeyService.keyEdge(
            wasPressed: true,
            eventKeyCode: ActivationKey.leftShift.keyCode,
            flags: CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | rightBit),
            registered: .leftShift
        )
        #expect(edge == .release)
    }

    @Test("events without device-specific bits fall back to the family flag")
    func syntheticEventFallback() {
        // Synthetic input / some remapping tools set only the family
        // mask. Detection must keep working for them: family present →
        // down, family absent → up.
        #expect(HotkeyService.isRegisteredKeyDown(
            flags: [.maskShift], registered: .rightShift
        ))
        #expect(!HotkeyService.isRegisteredKeyDown(
            flags: [], registered: .rightShift
        ))
    }

    @Test("Fn has no left/right sibling and uses the family flag alone")
    func fnUsesFamilyFlag() {
        #expect(HotkeyService.isRegisteredKeyDown(
            flags: [.maskSecondaryFn], registered: .fn
        ))
        #expect(!HotkeyService.isRegisteredKeyDown(
            flags: [], registered: .fn
        ))
    }
}
