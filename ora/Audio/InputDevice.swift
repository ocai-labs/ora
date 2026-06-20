//
//  InputDevice.swift
//  ora
//
//  One enumerated Core Audio input device. UID is the stable identity
//  (persists across reboots and reconnects — HAL
//  `kAudioDevicePropertyDeviceUID`); `audioDeviceID` is the ephemeral
//  `AudioDeviceID` handle that is only valid between enumeration and
//  immediate use. `name` is the human-readable label shown in the
//  menu.
//

import CoreAudio
import Foundation

struct InputDevice: Identifiable, Hashable, Sendable {
    let uid: String
    let name: String
    let audioDeviceID: AudioDeviceID

    var id: String { uid }
}

extension InputDevice {
    static func == (lhs: InputDevice, rhs: InputDevice) -> Bool {
        // UID is the identity. Two enumerations of the same physical
        // device can report different `AudioDeviceID`s, so we exclude
        // `id` from equality to keep diffing in SwiftUI stable.
        lhs.uid == rhs.uid && lhs.name == rhs.name
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(uid)
        hasher.combine(name)
    }
}
