//
//  ModelsPage.swift
//  ora
//
//  Models page — browser for local + API transcription models.
//  Reads the catalog from ModelManager in the environment; mutations
//  (download / cancel / remove) go through manager methods on the cards.
//

import SwiftUI

// MARK: - Filter

private enum ModelFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case local = "Local"
    case api = "API"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: "square.grid.2x2"
        case .local: "desktopcomputer"
        case .api: "chevron.left.forwardslash.chevron.right"

        }
    }
}

// MARK: - Main View

struct ModelsPage: View {
    @Environment(Preferences.self) private var preferences
    @Environment(ModelManager.self) private var modelManager
    @State private var selectedFilter: ModelFilter = .local

    private var filteredModels: [ModelEntry] {
        switch selectedFilter {
        case .all: modelManager.catalog
        case .local: modelManager.catalog.filter(\.isLocal)
        case .api: modelManager.catalog.filter(\.isOnline)
        }
    }

    private var localModels: [ModelEntry] {
        filteredModels.filter(\.isLocal)
    }

    private var apiModels: [ModelEntry] {
        filteredModels.filter { !$0.isLocal }
    }

    var body: some View {
        @Bindable var preferences = preferences
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                // Filter chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ModelFilter.allCases) { filter in
                            filterChip(filter)
                        }
                    }
                    .padding(.horizontal, 20)
                }

                // Grouped model lists
                VStack(alignment: .leading, spacing: 18) {
                    if !localModels.isEmpty {
                        modelGroup(title: "Local Models", entries: localModels) { model in
                            ModelCard(
                                model: model,
                                selectedModelId: $preferences.selectedModelId
                            ) {
                                LocalModelSettingsSheet(
                                    modelId: model.id,
                                    onRemoved: { handleRemoved(model.id) }
                                )
                            }
                        }
                    }
                    if !apiModels.isEmpty {
                        modelGroup(title: "API Models", entries: apiModels) { model in
                            ModelCard(
                                model: model,
                                selectedModelId: $preferences.selectedModelId
                            ) {
                                APISettingsSheet(
                                    providerId: model.id,
                                    providerName: model.name
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Model Group

    private func modelGroup<Card: View>(
        title: String,
        entries: [ModelEntry],
        @ViewBuilder card: @escaping (ModelEntry) -> Card
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 10) {
                ForEach(entries) { model in
                    card(model)
                }
            }
        }
    }

    // MARK: - Filter Chip

    private func filterChip(_ filter: ModelFilter) -> some View {
        let isSelected = selectedFilter == filter
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedFilter = filter
            }
        } label: {
            Label(filter.rawValue, systemImage: filter.icon)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.blue.opacity(0.15) : Color.clear)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isSelected ? Color.blue : Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .foregroundStyle(isSelected ? .blue : .primary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Selection bookkeeping

    /// Card-local handlers update model status themselves; the page only needs
    /// to know when to drop a stale selection and pick a fallback.
    private func handleRemoved(_ id: String) {
        guard preferences.selectedModelId == id else { return }
        preferences.selectedModelId =
            modelManager.catalog.first(where: {
                if case .downloaded = $0.status { return $0.isLocal && $0.id != id }
                return false
            })?.id
    }

}

#Preview {
    ModelsPage()
        .environment(Preferences.shared)
        .environment(ModelManager.shared)
        .frame(width: 540, height: 600)
}
