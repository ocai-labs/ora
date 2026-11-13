//
//  LocalModelSettingsSheet.swift
//  ora
//
//  Settings sheet for a locally-runnable transcription model. Shows model
//  info (size, language, speed) with download control in the title bar.
//

import SwiftUI

struct LocalModelSettingsSheet: View {
    let modelId: String
    var onRemoved: () -> Void = {}

    @Environment(ModelManager.self) private var modelManager
    @Bindable private var preferences = Preferences.shared
    @Environment(\.dismiss) private var dismiss
    @State private var removeConfirmPresented = false

    /// Live model state from the catalog — updates during downloads.
    /// Only reached from `sheetContent`, which `body` gates on the
    /// entry existing; everything below runs in the same main-actor
    /// body evaluation, so the entry can't vanish in between.
    private var model: ModelEntry {
        modelManager.catalog.first(where: { $0.id == modelId })!
    }

    var body: some View {
        if modelManager.catalog.contains(where: { $0.id == modelId }) {
            sheetContent
        } else {
            // Not possible today — catalog entries are never removed —
            // but dismissing beats crashing if that ever changes.
            Color.clear
                .frame(width: 380, height: 280)
                .onAppear { dismiss() }
        }
    }

    private var sheetContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Header: [title + ETA + download control] on one row, description below
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(model.name)
                        .font(.system(size: 15, weight: .semibold))

                    Spacer()

                    downloadControl
                }

                Text(model.description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Model info
            infoGrid
            Spacer()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380, height: 280)
        .alert(
            "Remove Model",
            isPresented: $removeConfirmPresented
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                handleRemove()
            }
        } message: {
            Text(
                "Are you sure you want to remove \"\(model.name)\"? You can download it again later."
            )
        }
    }

    // MARK: - Download Control (inline icon, top-right)

    @ViewBuilder
    private var downloadControl: some View {
        let size: CGFloat = 16

        HStack(spacing: 6) {
            if !captionText.isEmpty {
                captionLabel(text: captionText)
            }

            switch model.status {
            case .notDownloaded:
                Button {
                    modelManager.download(model.id)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: size))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .frame(width: size, height: size)

            case .downloading(let fraction, _):
                Button {
                    modelManager.cancel(model.id)
                } label: {
                    DownloadProgressIcon(fraction: fraction, size: size)
                }
                .buttonStyle(.plain)
                .frame(width: size, height: size)

            case .paused:
                Button {
                    modelManager.download(model.id)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: size))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .frame(width: size, height: size)

            case .extracting:
                SpinningCircle(size: size)
                    .frame(width: size, height: size)

            case .downloaded:
                Button {
                    removeConfirmPresented = true
                } label: {
                    Image(systemName: "trash.circle")
                        .font(.system(size: size))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: size, height: size)

            case .error(let message):
                Button {
                    modelManager.download(model.id)
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: size))
                        .foregroundStyle(.red)
                        .help(message)
                }
                .buttonStyle(.plain)
                .frame(width: size, height: size)
            }
        }
    }

    /// The caption text for the current status. Empty string means
    /// "reserve the space but show nothing" (opacity 0).
    private var captionText: String {
        switch model.status {
        case .downloading(_, let eta):
            Self.downloadingCaption(eta: eta) ?? ""
        case .paused:
            "Paused"
        default:
            ""
        }
    }

    private func captionLabel(text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    // MARK: - Model Info Grid

    private var infoGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            infoRow(icon: "internaldrive", label: "Size", value: model.size)
            if model.id == NemotronUnifiedTranscriber.modelId {
                languagePickerRow(
                    selection: $preferences.nemotronUnifiedLanguage,
                    options: Self.nemotronUnifiedLanguageOptions)
            } else if model.id == NemotronStreamingTranscriber.modelId {
                languagePickerRow(
                    selection: $preferences.nemotronStreamingLanguage,
                    options: Self.nemotronStreamingLanguageOptions)
            } else {
                infoRow(icon: "globe", label: "Language", value: model.language)
            }
            infoRow(icon: "bolt.fill", label: "Speed", value: speedLabel)
            infoRow(icon: "scope", label: "Accuracy", value: accuracyLabel)
        }
    }

    private func infoRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .center)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
        }
    }

    /// The Nemotron models take the language as an input, so their
    /// sheets get a picker instead of the read-only row. Pinning it is
    /// what keeps, e.g., French speech from coming out with English
    /// words, or Mandarin from drifting into Japanese.
    private func languagePickerRow(
        selection: Binding<String>,
        options: [(code: String, name: String)]
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .center)
            Text("Language")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Picker("Language", selection: selection) {
                Text("Auto-detect").tag("auto")
                Divider()
                ForEach(options, id: \.code) { option in
                    Text(option.name).tag(option.code)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
        }
    }

    /// Nemotron Unified's 25 languages, named in the user's own locale
    /// and sorted by that name.
    private static let nemotronUnifiedLanguageOptions: [(code: String, name: String)] =
        NemotronUnifiedTranscriber.languageCodes
            .map { code in
                let name = Locale.current.localizedString(forLanguageCode: code)?
                    .localizedCapitalized ?? code
                return (code, name)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    /// Nemotron 3.5 Streaming's locales (e.g. "zh-CN", "zh-TW"), named
    /// with their region so the two Chinese scripts / two Englishes are
    /// told apart, in the user's own locale and sorted by that name.
    private static let nemotronStreamingLanguageOptions: [(code: String, name: String)] =
        NemotronStreamingTranscriber.languageCodes
            .map { code in
                let name = Locale.current.localizedString(forIdentifier: code.replacingOccurrences(of: "-", with: "_"))?
                    .localizedCapitalized ?? code
                return (code, name)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    private var speedLabel: String {
        switch model.speed {
        case 5: "Very Fast"
        case 4: "Fast"
        case 3: "Moderate"
        case 2: "Slow"
        default: "Very Slow"
        }
    }

    private var accuracyLabel: String {
        switch model.accuracy {
        case 5: "Excellent"
        case 4: "Very Good"
        case 3: "Good"
        case 2: "Fair"
        default: "Basic"
        }
    }

    // MARK: - ETA Formatting

    private static func downloadingCaption(eta: TimeInterval?) -> String? {
        guard let eta else { return "Preparing" }
        let total = Int(eta.rounded())
        if total < 5 { return "less than 5s" }
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        let seconds = total % 60
        if minutes < 60 {
            return seconds == 0 ? "\(minutes)m" : "\(minutes)m\(seconds)s"
        }
        let hours = minutes / 60
        let mins = minutes % 60
        return mins == 0 ? "\(hours)h" : "\(hours)h\(mins)m"
    }

    // MARK: - Actions

    private func handleRemove() {
        do {
            try modelManager.remove(model.id)
            onRemoved()
            dismiss()
        } catch {
            // Remove failures are rare; on-disk state recovers on next launch.
        }
    }
}

// MARK: - Download Progress Icon

/// A download arrow icon surrounded by a circular progress ring.
/// When fraction is nil (preparing), the ring spins indeterminately.
struct DownloadProgressIcon: View {
    let fraction: Double?
    let size: CGFloat

    @State private var spinning: Double = 0

    var body: some View {
        ZStack {
            // Track circle (faint background ring)
            Circle()
                .stroke(Color.blue.opacity(0.15), lineWidth: 1.5)

            if let fraction {
                // Determinate progress ring
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.3), value: fraction)
            } else {
                // Indeterminate spinner
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(spinning))
                    .onAppear {
                        withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                            spinning = 360
                        }
                    }
            }

            // Download arrow icon inside
            Image(systemName: "arrow.down")
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.blue)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Spinner

private struct SpinningCircle: View {
    let size: CGFloat
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(Color.blue, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}
