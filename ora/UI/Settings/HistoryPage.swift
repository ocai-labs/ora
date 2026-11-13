//
//  HistoryPage.swift
//  ora
//
//  History settings page — the last `HistoryStore.maxEntries`
//  recordings and their transcripts, stored on this Mac. Each row can
//  play and scrub its audio and copy the text; its ⋯ menu regenerates
//  the transcript with another usable model or deletes it. "Save
//  recordings" off wipes the history (after a confirmation) and stops
//  saving new ones.
//

import AVFoundation
import SwiftUI

struct HistoryPage: View {
    @Environment(Preferences.self) private var preferences
    @Environment(HistoryStore.self) private var history
    @State private var player = HistoryPlayer()
    @State private var confirmClearAll = false
    @State private var confirmTurnOff = false

    var body: some View {
        Form {
            Section {
                Toggle("Save recordings", isOn: saveHistoryBinding)
                LabeledContent("Saved") {
                    HStack(spacing: 12) {
                        Text("\(history.entries.count) of \(HistoryStore.maxEntries)")
                            .monospacedDigit()
                        Button("Clear All…", role: .destructive) {
                            confirmClearAll = true
                        }
                        .disabled(history.entries.isEmpty)
                    }
                }
            } footer: {
                Text("Recordings and transcripts are stored on this Mac only. The last \(HistoryStore.maxEntries) are kept; turning Save recordings off deletes them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if history.entries.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Recordings",
                        systemImage: "waveform",
                        description: Text(preferences.saveHistory
                            ? "Your dictations will appear here."
                            : "Turn on Save recordings to keep your recent dictations.")
                    )
                }
            } else {
                // Reads the model catalog, so the Regenerate menus
                // refresh when a model is downloaded or removed.
                let models = DictationCoordinator.shared.regenerationModels()
                Section("Recent") {
                    ForEach(history.entries) { entry in
                        HistoryRow(entry: entry, player: player, models: models)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { player.stop() }
        .onChange(of: history.entries.map(\.id)) { _, ids in
            if let active = player.activeID, !ids.contains(active) { player.stop() }
        }
        .confirmationDialog(
            "Delete all saved recordings?",
            isPresented: $confirmClearAll
        ) {
            Button("Delete All", role: .destructive) {
                player.stop()
                history.clearAll()
            }
        } message: {
            Text("Their audio and transcripts are removed from this Mac. This can't be undone.")
        }
        .confirmationDialog(
            "Stop saving recordings?",
            isPresented: $confirmTurnOff
        ) {
            Button("Turn Off and Delete", role: .destructive) {
                player.stop()
                preferences.saveHistory = false
                history.clearAll()
            }
        } message: {
            Text("The \(history.entries.count) saved recordings and their transcripts are deleted. This can't be undone.")
        }
    }

    /// Turning the setting off with recordings on disk asks first;
    /// with nothing saved it just turns off.
    private var saveHistoryBinding: Binding<Bool> {
        Binding(
            get: { preferences.saveHistory },
            set: { newValue in
                if newValue {
                    preferences.saveHistory = true
                } else if history.entries.isEmpty {
                    preferences.saveHistory = false
                } else {
                    confirmTurnOff = true
                }
            }
        )
    }
}

// MARK: - Row

/// One recording. Layout, top to bottom, all on one left edge:
/// a caption line (model · length · time, plus Copy and a ⋯ menu on
/// the right), a playback row (play/pause + full-width scrubber +
/// time), and the transcript (3 lines, with a plain Show More / Show
/// Less at the bottom right when it's longer). Regenerate
/// and Delete are rarely used, so they live in the ⋯ menu.
private struct HistoryRow: View {
    let entry: HistoryEntry
    let player: HistoryPlayer
    let models: [ModelEntry]
    @Environment(HistoryStore.self) private var history
    @State private var audioAvailable = true
    /// Scrubber value while the user is dragging; nil otherwise.
    @State private var scrubValue: Double?

    /// Long transcripts show this many lines until expanded — no inner
    /// scroll view, so the page has exactly one scroll.
    private static let collapsedLines = 3
    @State private var isExpanded = false
    @State private var shownTextHeight: CGFloat = 0
    @State private var fullTextHeight: CGFloat = 0

    private var isRegenerating: Bool { history.regeneratingIDs.contains(entry.id) }
    private var isActive: Bool { player.activeID == entry.id }
    private var isPlaying: Bool { isActive && player.isPlaying }
    private var length: Double { max(entry.duration, 0.1) }
    private var canRegenerate: Bool {
        audioAvailable && !isRegenerating && !models.isEmpty && entry.status != .pending
    }

    var body: some View {
        // Header and its scrubber sit close together (both are about
        // the audio); the transcript gets a bigger gap below them.
        VStack(alignment: .leading, spacing: 0) {
            captionLine
            playbackRow
                .padding(.top, 4)
            transcript
                .padding(.top, 10)
            if let error = history.regenerateErrors[entry.id] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, 6)
            }
        }
        .padding(.vertical, 6)
        .task(id: entry.id) {
            audioAvailable = await history.audioExists(for: entry)
        }
    }

    // MARK: Caption line

    private var captionLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(entry.modelName)
                .fontWeight(.semibold)
            Text(Self.timeText(entry.duration))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text("·")
                .foregroundStyle(.secondary)
            Text(entry.createdAt, format: .relative(presentation: .named))
                .foregroundStyle(.secondary)
                .help(entry.createdAt.formatted(date: .complete, time: .shortened))

            if entry.status == .failed {
                Text("Failed")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .foregroundStyle(.red)
                    .background(.red.opacity(0.12), in: Capsule())
            }

            Spacer(minLength: 8)

            if isRegenerating {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                guard let text = entry.text else { return }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(entry.text?.isEmpty ?? true)
            .help("Copy transcript")

            Menu {
                Menu("Regenerate With") {
                    ForEach(models) { model in
                        Button {
                            Task {
                                await DictationCoordinator.shared.regenerate(entryID: entry.id, modelId: model.id)
                            }
                        } label: {
                            if model.id == entry.modelId {
                                Label(model.name, systemImage: "checkmark")
                            } else {
                                Text(model.name)
                            }
                        }
                    }
                }
                .disabled(!canRegenerate)

                Divider()

                Button("Delete", role: .destructive) {
                    if isActive { player.stop() }
                    history.delete(id: entry.id)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help(entry.status == .pending ? "Still transcribing" : "More")
        }
        .font(.callout)
    }

    // MARK: Transcript

    @ViewBuilder
    private var transcript: some View {
        if let text = entry.text, !text.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .textSelection(.enabled)
                    .lineLimit(isExpanded ? nil : Self.collapsedLines)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .readHeight(ShownHeightKey.self, into: $shownTextHeight)
                    // The same text, unclamped and invisible, to learn
                    // whether the clamp actually cut anything off.
                    .background(alignment: .topLeading) {
                        Text(text)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .hidden()
                            .readHeight(FullHeightKey.self, into: $fullTextHeight)
                    }

                if isExpanded || fullTextHeight > shownTextHeight + 1 {
                    HStack {
                        Spacer()
                        Button {
                            isExpanded.toggle()
                        } label: {
                            Text(isExpanded ? "Show Less" : "Show More")
                                .contentShape(Rectangle())
                        }
                        // Secondary, not link-blue: a quiet control that
                        // doesn't compete with the transcript.
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    }
                }
            }
        } else if entry.status == .pending {
            Text("Transcribing…")
                .foregroundStyle(.secondary)
        } else if entry.status == .failed {
            Text(audioAvailable
                ? "Nothing was pasted. The audio is saved; use ⋯ › Regenerate With to try again."
                : "The audio file is missing, so this can't be regenerated.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Playback row

    private var playbackRow: some View {
        HStack(spacing: 8) {
            Button {
                player.toggle(id: entry.id, url: history.audioURL(for: entry))
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 14)
            }
            .buttonStyle(.borderless)
            .help(isPlaying ? "Pause" : "Play recording")

            Slider(value: scrubBinding, in: 0...length) { editing in
                if !editing, let value = scrubValue {
                    player.seek(id: entry.id, url: history.audioURL(for: entry), to: value)
                    scrubValue = nil
                }
            }
            .controlSize(.small)
            // In a grouped Form an unlabeled control is pushed into the
            // trailing (value) column; hiding the label lets the slider
            // take the whole row from the left edge.
            .labelsHidden()
            .frame(maxWidth: .infinity)

            Text("\(Self.timeText(displayedPosition)) / \(Self.timeText(entry.duration))")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .disabled(!audioAvailable)
        .help(audioAvailable ? "Drag to scrub" : "Audio file is missing")
    }

    private var displayedPosition: Double {
        min(scrubValue ?? (isActive ? player.position : 0), length)
    }

    private var scrubBinding: Binding<Double> {
        Binding(
            get: { displayedPosition },
            set: { scrubValue = $0 }
        )
    }

    /// m:ss, never below 0:00.
    static func timeText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Height reading

// Two keys, not one: the full-text reader sits inside the shown-text
// reader's view tree, and a shared key would merge the two heights.
private struct ShownHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct FullHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    /// Writes this view's rendered height into `height`, via `key`.
    func readHeight<K: PreferenceKey>(_ key: K.Type, into height: Binding<CGFloat>) -> some View
    where K.Value == CGFloat {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: key, value: proxy.size.height)
            }
        }
        .onPreferenceChange(key) { height.wrappedValue = $0 }
    }
}

// MARK: - Playback

/// Plays one history recording at a time and tracks its position so
/// the row's scrubber can follow and seek. The active recording stays
/// loaded while paused so play resumes where it left off.
@MainActor
@Observable
final class HistoryPlayer: NSObject, AVAudioPlayerDelegate {
    /// The recording loaded in the player (playing or paused).
    private(set) var activeID: UUID?
    private(set) var isPlaying = false
    /// Current playback position of `activeID`, in seconds.
    private(set) var position: TimeInterval = 0

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    /// Play/pause `id`. Switching to another recording stops the
    /// current one.
    func toggle(id: UUID, url: URL) {
        if activeID == id, let player {
            if player.isPlaying {
                player.pause()
                isPlaying = false
                stopTicker()
            } else {
                startPlaying()
            }
            return
        }
        guard load(id: id, url: url) else { return }
        startPlaying()
    }

    /// Moves `id`'s playhead to `time`. Loads it (paused) when it isn't
    /// the active recording; keeps playing if it already was.
    func seek(id: UUID, url: URL, to time: TimeInterval) {
        if activeID != id {
            guard load(id: id, url: url) else { return }
        }
        guard let player else { return }
        player.currentTime = min(max(0, time), player.duration)
        position = player.currentTime
    }

    func stop() {
        stopTicker()
        player?.stop()
        player = nil
        activeID = nil
        isPlaying = false
        position = 0
    }

    private func load(id: UUID, url: URL) -> Bool {
        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            self.player = player
            activeID = id
            return true
        } catch {
            NSLog("[History] playback failed: %@", String(describing: error))
            return false
        }
    }

    private func startPlaying() {
        guard let player, player.play() else { return }
        isPlaying = true
        stopTicker()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let player = self.player else { return }
                self.position = player.currentTime
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor in
            if let current = self.player, ObjectIdentifier(current) == finished {
                self.stop()
            }
        }
    }
}

#Preview {
    HistoryPage()
        .environment(Preferences.shared)
        .environment(HistoryStore.shared)
        .frame(width: 520, height: 500)
}
