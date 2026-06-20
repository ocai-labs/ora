//
//  DictationPage.swift
//  ora
//
//  Dictation trigger settings — hotkey shortcut and input mode.
//

import SwiftUI

struct DictationPage: View {
    @Environment(Preferences.self) private var preferences
    @Environment(InputDeviceStore.self) private var inputDevices
    @State private var testInput: String = ""
    @FocusState private var isTestFocused: Bool

    /// Sentinel UID used by the Input Source picker to represent
    /// "Follow System Default". Chosen to never collide with a real
    /// Core Audio UID (which are always non-empty).
    private static let systemDefaultUID = ""

    private let notificationSounds = ["Pop", "Tink", "Glass", "Hero"]

    var body: some View {
        @Bindable var preferences = preferences
        return Form {
            Section("Input") {
                Picker("Microphone", selection: inputSourceBinding) {
                    Text("System Default").tag(Self.systemDefaultUID)
                    if !inputDevices.devices.isEmpty {
                        Divider()
                        ForEach(inputDevices.devices) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                }
            }

            Section("Output") {
                Toggle("Paste transcript automatically", isOn: $preferences.autoPaste)
            }

            Section("Notifications") {
                Toggle("Play sound", isOn: $preferences.notificationSoundEnabled)

                Picker("Sound", selection: $preferences.notificationSoundName) {
                    ForEach(notificationSounds, id: \.self) { sound in
                        Text(sound).tag(sound)
                    }
                }
                .disabled(!preferences.notificationSoundEnabled)
            }

            Section("Trigger") {
                Picker("Shortcut", selection: $preferences.activationKey) {
                    ForEach(ActivationKey.allCases) { key in
                        Text(key.rawValue).tag(key)
                    }
                }
                .onChange(of: preferences.activationKey) { _, _ in
                    DictationCoordinator.shared.updateHotkey()
                }

                Picker("Mode", selection: $preferences.activationMode) {
                    ForEach(ActivationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(preferences.activationMode.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Try It Out") {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $testInput)
                        .font(.body)
                        .focused($isTestFocused)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 80)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    isTestFocused ? Color.accentColor : Color(nsColor: .separatorColor),
                                    lineWidth: isTestFocused ? 2 : 1
                                )
                        )

                    if testInput.isEmpty {
                        Text("Hold \(preferences.activationKey.rawValue) and speak to test…")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(12)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { inputDevices.refresh() }
    }

    /// Bridges `InputDeviceStore`'s `String?` selection ("nil = follow
    /// system default") to a non-optional `String` binding for SwiftUI's
    /// `Picker`, using an empty-string sentinel. A stale persisted UID
    /// (device unplugged) also surfaces as "System Default" so the
    /// picker visually matches the recorder's fallback behavior.
    private var inputSourceBinding: Binding<String> {
        Binding(
            get: {
                guard let uid = inputDevices.selectedUID,
                      inputDevices.devices.contains(where: { $0.uid == uid })
                else { return Self.systemDefaultUID }
                return uid
            },
            set: { newValue in
                inputDevices.select(uid: newValue == Self.systemDefaultUID ? nil : newValue)
            }
        )
    }
}

#Preview {
    DictationPage()
        .environment(Preferences.shared)
        .frame(width: 500, height: 400)
}
