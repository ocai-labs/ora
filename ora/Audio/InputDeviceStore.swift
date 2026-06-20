//
//  InputDeviceStore.swift
//  ora
//
//  App-wide source of truth for the "which input device should the
//  recorder use?" setting. Enumerates Core Audio HAL input devices,
//  publishes the current list and selected UID, persists the
//  selection via `Preferences`, and resolves UID → ephemeral
//  `AudioDeviceID` at record time.
//
//  ## Why UID is the identity
//
//  `AudioDeviceID` is an unsigned-int handle that Core Audio hands out
//  per enumeration — it can change across device reconnects and
//  sometimes across reboots. `kAudioDevicePropertyDeviceUID` returns
//  a stable `CFString` identity that persists, so we persist THAT and
//  re-resolve to an `AudioDeviceID` every time we need to apply the
//  override.
//
//  ## Silent-fallback policy
//
//  If the persisted UID isn't in the current enumeration (device
//  unplugged), `resolveSelectedDeviceID()` returns `nil` and the
//  recorder falls back to the system default. We don't surface a
//  warning — see the design spec's scope-B decision.
//

import CoreAudio
import Foundation
import Observation

@MainActor
@Observable
final class InputDeviceStore {
    private(set) var devices: [InputDevice] = []
    private(set) var selectedUID: String?

    @ObservationIgnored private let preferences: Preferences

    init(preferences: Preferences) {
        self.preferences = preferences
        self.selectedUID = preferences.selectedInputDeviceUID
    }

    /// Updates the selected UID and persists it. Pass `nil` to fall
    /// back to "Follow System Default".
    func select(uid: String?) {
        selectedUID = uid
        preferences.selectedInputDeviceUID = uid
    }

    /// True when the menu should draw a checkmark next to "System
    /// Default": either nothing is selected, or the persisted UID
    /// doesn't match any currently-enumerated device (stale → we're
    /// effectively following the system default at record time).
    static func isSystemDefaultChecked(selectedUID: String?, devices: [InputDevice]) -> Bool {
        guard let selectedUID else { return true }
        return !devices.contains(where: { $0.uid == selectedUID })
    }

    // MARK: - HAL enumeration

    /// Re-enumerates Core Audio input devices and publishes the list.
    /// Cheap enough to call on every menu open — a typical Mac reports
    /// 2–5 devices and the whole pass is a handful of HAL property
    /// reads.
    ///
    /// The equality guard is load-bearing: `MenuBarView.body` calls
    /// `refresh()` on every menu-open body-evaluation. Without the
    /// guard, every call would write to `devices` and trigger another
    /// body eval via `@Observable`, looping. With the guard, the
    /// write only happens when the device list actually changed, so
    /// steady-state re-opens are free.
    func refresh() {
        let fresh = Self.enumerateInputDevices()
        // InputDevice.== ignores audioDeviceID on purpose (UID is the
        // stable identity), so also publish when only the ephemeral
        // HAL ids changed — the same mic unplugged and replugged gets
        // a new AudioDeviceID, and consumers of the published list
        // must not be left holding the dead one. Steady-state
        // re-opens still skip the write (see equality-guard note).
        if fresh != devices || fresh.map(\.audioDeviceID) != devices.map(\.audioDeviceID) {
            devices = fresh
        }
    }

    /// Re-enumerates and returns the current `AudioDeviceID` for the
    /// stored `selectedUID`, or `nil` if nothing is pinned or the
    /// pinned device is not currently present.
    func resolveSelectedDeviceID() -> AudioDeviceID? {
        guard let selectedUID else { return nil }
        let current = Self.enumerateInputDevices()
        return current.first(where: { $0.uid == selectedUID })?.audioDeviceID
    }

    // MARK: - Core Audio property reads

    private static func enumerateInputDevices() -> [InputDevice] {
        let ids = allAudioDeviceIDs()
        var result: [InputDevice] = []
        result.reserveCapacity(ids.count)
        for id in ids {
            // Skip devices the system marks as hidden — e.g.
            // `CADefaultDeviceAggregate`, which macOS exposes as an
            // internal wrapper around the current default input and
            // which would show up as a confusing duplicate of our
            // own "System Default" entry. User-created aggregates
            // and third-party virtual mics (BlackHole, Loopback,
            // meeting-app audio drivers) do NOT set this flag, so
            // they stay visible.
            if deviceIsHidden(id) { continue }

            guard deviceHasInputStreams(id),
                  let uid = deviceStringProperty(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = deviceStringProperty(id, selector: kAudioObjectPropertyName)
            else { continue }
            result.append(InputDevice(uid: uid, name: name, audioDeviceID: id))
        }
        return result
    }

    /// Reads `kAudioDevicePropertyIsHidden`. Core Audio sets this for
    /// devices that shouldn't appear in user-facing pickers — most
    /// notably the default-aggregate wrapper. Returns `false` on any
    /// HAL error (fail-open: better to show a device than hide a
    /// real one).
    private static func deviceIsHidden(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isHidden: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, &isHidden)
        guard status == noErr else { return false }
        return isHidden != 0
    }

    private static func allAudioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard sizeStatus == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let readStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &ids
        )
        guard readStatus == noErr else { return [] }
        return ids
    }

    /// True if `id` exposes at least one input stream with non-zero
    /// channel count. Filters out output-only devices and weird
    /// aggregate setups that expose a device with zero input streams.
    private static func deviceHasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize > 0 else { return false }

        let bufferListPtr = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListPtr.deallocate() }

        let readStatus = AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, bufferListPtr)
        guard readStatus == noErr else { return false }

        let abl = bufferListPtr.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        for buffer in buffers where buffer.mNumberChannels > 0 {
            return true
        }
        return false
    }

    /// Reads a CFString-valued HAL property (UID, human name) on the
    /// global scope of `id` and bridges it to `String`. Uses
    /// `Unmanaged<CFString>` because HAL returns a retained (+1)
    /// reference under the Core Foundation "Copy" rule, and because
    /// passing `&cfString` for a bare `CFString?` trips a Swift warning
    /// about forming a raw pointer to an object reference.
    private static func deviceStringProperty(
        _ id: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var cfString: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, &cfString)
        guard status == noErr, let cfString else { return nil }
        return cfString.takeRetainedValue() as String
    }
}
