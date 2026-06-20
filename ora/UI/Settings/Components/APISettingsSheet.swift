//
//  APISettingsSheet.swift
//  ora
//
//  Settings sheet for API-based transcription providers (API key + model).
//

import SwiftUI

// MARK: - API Settings Sheet

struct APISettingsSheet: View {
    let providerId: String
    let providerName: String

    @Environment(\.dismiss) private var dismiss
    @State private var apiKey: String = ""
    @State private var selectedModel: String = ""
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("\(providerName) Settings")
                .font(.system(size: 15, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("API Key")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                SecureField("sk-...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Model")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(Self.modelPlaceholder(for: providerId), text: $selectedModel)
                    .textFieldStyle(.roundedBorder)
            }

            Spacer()

            if let saveError {
                Text(saveError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    if save() { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360, height: 240)
        .onAppear(perform: load)
    }

    private func load() {
        let defaults = UserDefaults.standard
        // One-shot migration from the old AppStorage-backed key location.
        // Zero out the plaintext copy once it's safely in the Keychain so
        // UserDefaults stops hoarding secrets for existing installs.
        let legacyKey = "api.\(providerId).key"
        if let legacy = defaults.string(forKey: legacyKey), !legacy.isEmpty {
            // Only drop the plaintext copy once the Keychain write
            // actually succeeded — otherwise a transient keychain
            // failure would destroy the user's only copy of the key.
            if (try? KeychainStore.setAPIKey(legacy, provider: providerId)) != nil {
                defaults.removeObject(forKey: legacyKey)
            }
        }
        apiKey = KeychainStore.apiKey(provider: providerId) ?? ""
        selectedModel = defaults.string(forKey: APITranscriber.modelDefaultsKey(for: providerId)) ?? ""
    }

    /// Persists the key + model. Returns false (and shows the error
    /// inline, keeping the sheet open) if the Keychain write failed —
    /// dismissing silently used to leave the user believing a key was
    /// saved (or cleared) when it wasn't.
    private func save() -> Bool {
        do {
            try KeychainStore.setAPIKey(apiKey, provider: providerId)
        } catch {
            saveError = error.localizedDescription
            return false
        }
        UserDefaults.standard.set(selectedModel, forKey: APITranscriber.modelDefaultsKey(for: providerId))
        return true
    }

    private static func modelPlaceholder(for providerId: String) -> String {
        switch providerId {
        case "openai-api": "e.g. gpt-4o-transcribe"
        case "groq-api": "e.g. whisper-large-v3"
        default: "Model name"
        }
    }
}
