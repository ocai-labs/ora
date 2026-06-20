//
//  ModelCard.swift
//  ora
//
//  Shared card UI for any transcription model (local or API).
//  The caller supplies the settings sheet that opens on the gear button.
//

import SwiftUI

struct ModelCard<SettingsSheet: View>: View {
    let model: ModelEntry
    @Binding var selectedModelId: String?
    @ViewBuilder var settingsSheet: () -> SettingsSheet

    @State private var isSettingsPresented = false

    private var isSelected: Bool { selectedModelId == model.id }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let asset = model.brandIconAsset {
                    Image(asset)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .frame(width: 32, height: 32)
                        .overlay(
                            Image(systemName: model.isLocal ? "eye" : "cloud.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(model.isLocal ? .green : .blue)
                        )
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .font(.system(size: 13, weight: .semibold))

                    if case .notDownloaded = model.status {
                        Text("Not Downloaded")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(Color.secondary.opacity(0.12))
                            )
                    }

                    Spacer()

                    settingsButton
                }

                Text(model.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(ModelCardChrome.background(isSelected: isSelected))
        .overlay(ModelCardChrome.border(isSelected: isSelected))
        .contentShape(Rectangle())
        .onTapGesture {
            if case .downloaded = model.status {
                selectedModelId = model.id
            }
        }
    }

    // MARK: - Settings Button

    private var settingsButton: some View {
        Button {
            isSettingsPresented = true
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .frame(width: 11, height: 11)
        .sheet(isPresented: $isSettingsPresented) {
            settingsSheet()
        }
    }
}

// MARK: - Shared Card Chrome

enum ModelCardChrome {
    static func background(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(isSelected
                  ? Color.blue.opacity(0.08)
                  : Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    static func border(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(
                isSelected ? Color.blue : Color.secondary.opacity(0.15),
                lineWidth: isSelected ? 1.5 : 0.5
            )
    }
}
