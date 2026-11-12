//
//  GeneralPage.swift
//  ora
//
//  General settings page — UI-only port from WhisperIsland, now with
//  Sparkle-backed "Check for Updates…" wired into the Other section.
//

import SwiftUI

struct GeneralPage: View {
    @Environment(Preferences.self) private var preferences
    @Environment(ModelManager.self) private var modelManager
    // ObservedObject, not StateObject: the view must not take
    // ownership of an externally-owned singleton (StateObject only
    // worked here by accident, because the singleton never deallocs).
    @ObservedObject private var updateController = UpdateController.shared

    var body: some View {
        @Bindable var preferences = preferences
        // Safety rail: don't let the user hide both the dock icon and the
        // status bar item at the same time, or the app becomes unreachable.
        let dockToggleLocked = preferences.showInDock && !preferences.showInStatusBar
        let statusToggleLocked = preferences.showInStatusBar && !preferences.showInDock
        return Form {
            Section("Interface") {
                Picker("Appearance", selection: $preferences.appearance) {
                    Text("System").tag(AppearanceMode.system)
                    Text("Light").tag(AppearanceMode.light)
                    Text("Dark").tag(AppearanceMode.dark)
                }

                Picker("Dictation Display", selection: $preferences.overlayStyle) {
                    ForEach(OverlayStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                // Notes render inside the demo canvas, not as separate
                // Form rows — extra rows add dividers that chop up the
                // Interface section.
                DictationDisplayDemo(style: preferences.overlayStyle, note: demoNote)
            }

            Section("Behavior") {
                Toggle("Show in Dock", isOn: $preferences.showInDock)
                    .disabled(dockToggleLocked)

                Toggle("Show in status bar", isOn: $preferences.showInStatusBar)
                    .disabled(statusToggleLocked)

                Toggle("Launch at login", isOn: $preferences.launchAtLogin)
            }

            Section("Other") {
                LabeledContent("Updates") {
                    Button("Check for Updates…") {
                        updateController.checkForUpdates()
                    }
                    .disabled(!updateController.canCheckForUpdates)
                }
                LabeledContent("Installed", value: versionString)
            }
        }
        .formStyle(.grouped)
    }

    private var versionString: String {
        #if DEBUG
        return "\(BuildInfo.marketingVersion)-dev (\(BuildInfo.gitCommitHash))"
        #else
        return "\(BuildInfo.marketingVersion) (\(BuildInfo.gitCommitHash))"
        #endif
    }

    /// Live preview is a model capability (spec §5.4/§6): when the
    /// Panel style is selected but the currently selected model can't
    /// produce partials, explain the compact degraded form — shown as
    /// a chip inside the demo canvas (the runtime overlay deliberately
    /// carries no explanation text).
    private var demoNote: String? {
        guard preferences.overlayStyle == .panel else { return nil }
        // Coalesce like every dictation call site does: a nil selection
        // falls back to the default model, so the note must judge the
        // model that would actually run.
        let effectiveId = preferences.selectedModelId ?? Preferences.defaultModelId
        let selected = modelManager.catalog.first { $0.id == effectiveId }
        guard !(selected?.supportsLivePreview ?? false) else { return nil }
        return "The selected model doesn't support live preview — while recording, the panel shows a compact waveform instead."
    }
}

// MARK: - Dictation Display demo

/// Self-contained live demo of the selected overlay style, rendered
/// with the *real* overlay views bound to a mock RecordingOverlayState
/// (spec §6 — no NSPanel involved). A task loop feeds a sine-ish fake
/// audio level; for the panel style it also replays a scripted partial
/// sequence (with a brief hold, then loops) that mimics the engine's
/// output — full-replacement frames at ~1 Hz, including a rewrite — so
/// the demo exercises the exact compact→full expansion, diff
/// crossfade, and tail-follow paths that real dictation does.
private struct DictationDisplayDemo: View {
    let style: OverlayStyle
    /// Optional notice (e.g. "the selected model doesn't support live
    /// preview"). When present it *becomes* the text the demo panel
    /// types out, replacing the sample transcript — the notice lives
    /// inside the demo instead of as an extra Form row (which would add
    /// a divider through the Interface section).
    var note: String? = nil

    @State private var mock = RecordingOverlayState()

    /// Scripted partial frames mirroring the real engine: each round
    /// replaces the whole text, several words at a time, and an early
    /// misrecognition gets rewritten ("life" → "live") so the diff
    /// crossfade shows up every loop (same idea as the scripts in
    /// spikes/diff-fade-demo.html). Long enough to overflow the
    /// panel's 4–5 visible lines, so the demo shows real tail-follow
    /// scrolling.
    private static let sampleFrames: [String] = {
        var frames = [
            "This is",
            "This is a life preview",   // ← rewritten next round
        ]
        var text = ""
        for chunk in [
            "This is a live preview of your dictation.",
            " As you speak, ora transcribes on the fly",
            " and shows the latest text right here,",
            " before anything is typed.",
            " When you release the hotkey, the final transcript",
            " is pasted into the field you were in —",
            " nothing is written until then,",
            " so your cursor and existing text stay untouched.",
        ] {
            text += chunk
            frames.append(text)
        }
        return frames
    }()

    /// What the panel demo plays: the notice (chunked into
    /// partial-sized appends) when one applies, the sample script
    /// otherwise.
    private var demoFrames: [String] {
        guard let note else { return Self.sampleFrames }
        let words = note.split(separator: " ")
        var frames: [String] = []
        var count = 0
        while count < words.count {
            count = min(count + 5, words.count)
            frames.append(words.prefix(count).joined(separator: " "))
        }
        return frames
    }

    /// Restart the demo loop when the style OR the note changes (model
    /// switched while Settings is open).
    private var taskKey: String { "\(style.rawValue)|\(note ?? "")" }

    /// Render scale: the panel's full-form canvas (600×168) is too wide
    /// for the settings window, so draw it at 0.7×.
    private static let scale: CGFloat = 0.7
    private static let canvas = PanelOverlayView.hostSize

    var body: some View {
        demoContent
            .allowsHitTesting(false)
            .frame(width: Self.canvas.width, height: Self.canvas.height)
            .scaleEffect(Self.scale)
            .frame(
                width: Self.canvas.width * Self.scale,
                height: Self.canvas.height * Self.scale
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(
                // Wallpaper-style backdrop so the demo reads as "this
                // floats over your screen" rather than a gray void.
                Image("DictationDemoBackground")
                    .resizable()
                    .scaledToFill()
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            // Don't let the overlay's text baselines escape into the Form.
            // Form rows align on text baselines, and alignment guides pass
            // straight through fixed frames and scaleEffect: once the demo
            // transcript tail-scrolls, its first (clipped) line sits above
            // the canvas and the row grew by ~15 pt to make room — the whole
            // General page jumped down, then back when the demo looped.
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.top] }
            .alignmentGuide(.lastTextBaseline) { $0[VerticalAlignment.bottom] }
            .task(id: taskKey) { await runDemo() }
    }

    @ViewBuilder
    private var demoContent: some View {
        switch style {
        case .pill:
            RecordingOverlayView(state: mock)
        case .panel:
            PanelOverlayView(state: mock)
        }
    }

    private func runDemo() async {
        mock.phase = .recording
        mock.audioLevel = 0
        mock.partialText = ""
        // The demo always shows the panel's full form — even when the
        // selected model is cloud-only — so the user sees what a local
        // model would unlock (spec §6).
        mock.supportsLivePreview = (style == .panel)

        var tick = 0
        var frameIndex = 0
        var holdTicks = 0

        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { break }
            tick += 1

            // Sine-ish fake speech level with a little jitter.
            let t = Double(tick) * 0.08
            let slow = (sin(t * 2.6) + 1) / 2
            let fast = (sin(t * 9.3) + 1) / 2
            let level = 0.2 + slow * 0.45 + fast * 0.35 * Double.random(in: 0.4...1)
            mock.audioLevel = Float(min(1, level))

            guard style == .panel else { continue }

            let frames = demoFrames
            if frameIndex < frames.count {
                // One full-replacement frame every 12 ticks (~960 ms) —
                // the engine's re-transcription cadence.
                if tick % 12 == 0 {
                    mock.partialText = frames[frameIndex]
                    frameIndex += 1
                }
            } else {
                // Hold the finished transcript briefly, then loop —
                // collapsing back to compact and re-expanding shows the
                // first-partial expansion animation each cycle.
                holdTicks += 1
                if holdTicks >= 25 {   // ~2 s
                    frameIndex = 0
                    holdTicks = 0
                    mock.partialText = ""
                }
            }
        }
    }
}

#Preview {
    GeneralPage()
        .environment(Preferences.shared)
        .environment(ModelManager.shared)
        .frame(width: 500, height: 600)
}
