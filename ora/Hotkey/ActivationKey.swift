//
//  ActivationKey.swift
//  ora
//
//  Predefined modifier-only activation keys for hold-to-talk.
//  Maps UI display names to CGKeyCode + CGEventFlags for detection
//  via a CGEventTap watching .flagsChanged events.
//

import Carbon.HIToolbox
import CoreGraphics

enum ActivationKey: String, CaseIterable, Identifiable, Codable {
    case rightCommand = "Right ⌘"
    case rightOption  = "Right ⌥"
    case rightShift   = "Right ⇧"
    case rightControl = "Right ⌃"
    case leftCommand  = "Left ⌘"
    case leftOption   = "Left ⌥"
    case leftShift    = "Left ⇧"
    case leftControl  = "Left ⌃"
    case fn           = "Fn"

    var id: String { rawValue }

    /// The virtual key code for this modifier key, used to identify
    /// which specific key changed in a `.flagsChanged` CGEvent.
    var keyCode: CGKeyCode {
        switch self {
        case .rightCommand: CGKeyCode(kVK_RightCommand)
        case .rightOption:  CGKeyCode(kVK_RightOption)
        case .rightShift:   CGKeyCode(kVK_RightShift)
        case .rightControl: CGKeyCode(kVK_RightControl)
        case .leftCommand:  CGKeyCode(kVK_Command)
        case .leftOption:   CGKeyCode(kVK_Option)
        case .leftShift:    CGKeyCode(kVK_Shift)
        case .leftControl:  CGKeyCode(kVK_Control)
        case .fn:           CGKeyCode(kVK_Function)
        }
    }

    /// The CGEventFlags mask for the modifier family this key belongs to.
    /// Used to determine press vs release: if the flag IS present in the
    /// event's flags after a flagsChanged, the key went down; if absent,
    /// it went up. Family masks can't tell left from right — see the
    /// device-specific masks below for that.
    var modifierFlag: CGEventFlags {
        switch self {
        case .rightCommand, .leftCommand: .maskCommand
        case .rightOption, .leftOption:   .maskAlternate
        case .rightShift, .leftShift:     .maskShift
        case .rightControl, .leftControl: .maskControl
        case .fn:                         .maskSecondaryFn
        }
    }

    /// IOKit `NX_DEVICE*KEYMASK` bit identifying this exact key (left
    /// vs right) in the low bits of `CGEventFlags.rawValue`. Physical
    /// keyboards set these on every flagsChanged event; they're what
    /// lets us see "right ⇧ went up" while left ⇧ keeps the family
    /// flag alive. `nil` for Fn, which has no left/right sibling.
    var deviceSpecificFlagMask: UInt64? {
        switch self {
        case .rightCommand: 0x0010  // NX_DEVICERCMDKEYMASK
        case .rightOption:  0x0040  // NX_DEVICERALTKEYMASK
        case .rightShift:   0x0004  // NX_DEVICERSHIFTKEYMASK
        case .rightControl: 0x2000  // NX_DEVICERCTLKEYMASK
        case .leftCommand:  0x0008  // NX_DEVICELCMDKEYMASK
        case .leftOption:   0x0020  // NX_DEVICELALTKEYMASK
        case .leftShift:    0x0002  // NX_DEVICELSHIFTKEYMASK
        case .leftControl:  0x0001  // NX_DEVICELCTLKEYMASK
        case .fn:           nil
        }
    }

    /// Union of both siblings' device-specific bits for this key's
    /// family. Used to detect whether an event carries device-level
    /// info at all — synthetic events and some remapping tools omit
    /// it, in which case detection falls back to the family flag.
    var familyDeviceFlagMask: UInt64? {
        switch self {
        case .rightCommand, .leftCommand: 0x0018
        case .rightOption, .leftOption:   0x0060
        case .rightShift, .leftShift:     0x0006
        case .rightControl, .leftControl: 0x2001
        case .fn:                         nil
        }
    }

    static let `default`: ActivationKey = .rightCommand
}
