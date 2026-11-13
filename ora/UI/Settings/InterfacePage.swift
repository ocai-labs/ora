//
//  InterfacePage.swift
//  ora
//
//  Interface settings: a live demo of the dictation overlay, the app
//  Appearance, what shows while recording (pill, its position, the live
//  transcription bubble) and the overlay glass tint.
//

import AppKit
import SwiftUI

struct InterfacePage: View {
    @Environment(Preferences.self) private var preferences
    @Environment(ModelManager.self) private var modelManager

    var body: some View {
        @Bindable var preferences = preferences
        return Form {
            Section {
                // Notes render inside the demo canvas, not as separate
                // Form rows.
                DictationDisplayDemo(
                    showPill: preferences.showRecordingPill,
                    pillPosition: preferences.pillPosition,
                    showLivePreview: preferences.showLivePreview,
                    note: demoNote
                )
            }

            Section {
                Picker("Appearance", selection: $preferences.appearance) {
                    Text("System").tag(AppearanceMode.system)
                    Text("Light").tag(AppearanceMode.light)
                    Text("Dark").tag(AppearanceMode.dark)
                }
            }

            Section("While Recording") {
                Toggle("Show recording pill", isOn: $preferences.showRecordingPill)

                Picker("Pill position", selection: $preferences.pillPosition) {
                    ForEach(PillPosition.allCases) { position in
                        Text(position.title).tag(position)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!preferences.showRecordingPill)

                Toggle("Show live transcription", isOn: $preferences.showLivePreview)

                Text(livePreviewFootnote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Overlay Glass") {
                LabeledContent("Tint") {
                    OverlayTintPicker(hex: $preferences.overlayTintHex)
                }

                // Also active under Automatic, where it sets how solid
                // the neutral glass is.
                Slider(value: $preferences.overlayTintStrength, in: OverlayTint.strengthRange) {
                    Text("Tint strength")
                }

                Button("Reset to Default") {
                    preferences.resetOverlayGlass()
                }
                .disabled(isGlassDefault)
            }
        }
        .formStyle(.grouped)
    }

    private var isGlassDefault: Bool {
        preferences.overlayTintHex == nil
            && preferences.overlayTintStrength == OverlayTint.defaultStrength
    }

    private var selectedModelSupportsLivePreview: Bool {
        // Coalesce like every dictation call site does: a nil selection
        // falls back to the default model, so the note must judge the
        // model that would actually run.
        let effectiveId = preferences.selectedModelId ?? Preferences.defaultModelId
        let selected = modelManager.catalog.first { $0.id == effectiveId }
        return selected?.supportsLivePreview ?? false
    }

    private var livePreviewFootnote: String {
        if !preferences.showRecordingPill && !preferences.showLivePreview {
            return "Nothing is shown while recording. Errors still appear in a pill."
        }
        if preferences.showLivePreview && !selectedModelSupportsLivePreview {
            return "The selected model doesn't support live preview — choose a local Parakeet, Nemotron or SenseVoice model to see your words as you speak."
        }
        return "Shows your words in a bubble at the bottom of the screen as you speak. Needs a local model with live preview."
    }

    /// Live preview is a model capability (spec §5.4/§6): when live
    /// transcription is on but the selected model can't produce
    /// partials, the demo bubble types this out instead of the sample
    /// transcript (the runtime overlay carries no explanation text).
    private var demoNote: String? {
        guard preferences.showLivePreview, !selectedModelSupportsLivePreview else { return nil }
        return "The selected model doesn't support live preview — while recording, only the waveform is shown."
    }
}

// MARK: - Tint picker

/// The overlay tint row: Automatic + preset swatches, then a native
/// ColorPicker for any other colour. `hex == nil` is Automatic.
private struct OverlayTintPicker: View {
    @Binding var hex: String?

    var body: some View {
        HStack(spacing: 8) {
            TintSwatch(name: "Automatic", fill: nil, isSelected: hex == nil) {
                hex = nil
            }
            ForEach(OverlayTint.presets) { preset in
                TintSwatch(
                    name: preset.name,
                    fill: Self.color(fromHex: preset.hex),
                    isSelected: hex?.uppercased() == preset.hex
                ) {
                    hex = preset.hex
                }
            }
            ColorPicker("Custom Color", selection: customColor, supportsOpacity: false)
                .labelsHidden()
                .help("Custom Color")
        }
    }

    /// The ColorPicker shows the current tint (or Blue under Automatic,
    /// as a neutral starting point) and writes any pick back as hex.
    private var customColor: Binding<Color> {
        Binding(
            get: {
                hex.flatMap(Self.color(fromHex:))
                    ?? Self.color(fromHex: OverlayTint.presets[1].hex) ?? .blue
            },
            set: { newValue in
                guard let srgb = NSColor(newValue).usingColorSpace(.sRGB) else { return }
                hex = OverlayTint.hex(
                    red: Double(srgb.redComponent),
                    green: Double(srgb.greenComponent),
                    blue: Double(srgb.blueComponent))
            }
        )
    }

    static func color(fromHex hex: String) -> Color? {
        OverlayTint.components(fromHex: hex).map { Color(.sRGB, red: $0.red, green: $0.green, blue: $0.blue) }
    }
}

private struct TintSwatch: View {
    let name: String
    /// nil = Automatic, drawn half light / half dark.
    let fill: Color?
    let isSelected: Bool
    let action: () -> Void

    private static let size: CGFloat = 16

    var body: some View {
        Button(action: action) {
            swatch
                .frame(width: Self.size, height: Self.size)
                .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
                .padding(3)
                .overlay(
                    Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                        .opacity(isSelected ? 1 : 0)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var swatch: some View {
        if let fill {
            Circle().fill(fill)
        } else {
            Circle().fill(
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0.5),
                        .init(color: Color(white: 0.2), location: 0.5),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing)
            )
        }
    }
}

// MARK: - Dictation display demo

/// Self-contained live demo of the overlay as the current settings lay
/// it out (OverlayLayout — the same mapping the real overlay uses),
/// rendered with the *real* overlay views bound to a mock
/// RecordingOverlayState (spec §6 — no NSPanel involved). The canvas is
/// a miniature screen: the top pill under its top edge, the bottom
/// panel along its bottom edge. A task loop feeds a sine-ish fake audio
/// level; with live transcription on it also replays a scripted partial
/// sequence (with a brief hold, then loops) that mimics the engine's
/// output — full-replacement frames at ~1 Hz, including a rewrite — so
/// the demo exercises the exact compact→full expansion, diff
/// crossfade, and tail-follow paths that real dictation does. The glass
/// tint and Appearance apply live, since the overlay views read them.
private struct DictationDisplayDemo: View {
    let showPill: Bool
    let pillPosition: PillPosition
    let showLivePreview: Bool
    /// Optional notice (e.g. "the selected model doesn't support live
    /// preview"). When present it *becomes* the text the demo bubble
    /// types out, replacing the sample transcript.
    var note: String? = nil

    @State private var mock = RecordingOverlayState()

    /// Scripted partial frames mirroring the real engine: each round
    /// replaces the whole text, several words at a time, and an early
    /// misrecognition gets rewritten ("life" → "live") so the diff
    /// crossfade shows up every loop. Long enough to overflow the
    /// bubble's 3 visible lines, so the demo shows real tail-follow
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
            " When you finish, the final transcript",
            " is pasted into the field you were in —",
            " nothing is written until then,",
            " so your cursor and existing text stay untouched.",
        ] {
            text += chunk
            frames.append(text)
        }
        return frames
    }()

    /// The notice (chunked into partial-sized appends) when one
    /// applies, the sample script otherwise.
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

    /// The demo always shows the bubble's full form when live
    /// transcription is on — even for a cloud-only model — so the user
    /// sees what a local model would unlock (spec §6).
    private var layout: OverlayLayout {
        OverlayLayout(
            showPill: showPill,
            position: pillPosition,
            showLivePreview: showLivePreview,
            phase: .recording,
            modelSupportsLivePreview: true)
    }

    /// Restart the loop (and remount the bottom panel, whose text
    /// column width depends on the layout) when anything changes.
    private var layoutKey: String {
        "\(showPill)|\(pillPosition.rawValue)|\(showLivePreview)|\(note ?? "")"
    }

    /// Render scale: a miniature screen with the real overlay views at
    /// 0.7×. Tall enough for the top pill panel above the bottom panel.
    private static let scale: CGFloat = 0.7
    private static let canvas = NSSize(
        width: PanelOverlayView.hostSize.width,
        height: RecordingOverlayView.hostHeight + PanelOverlayView.hostSize.height)

    var body: some View {
        demoContent
            .environment(\.oraOverlayBlendsWithinWindow, true)
            .allowsHitTesting(false)
            .frame(width: Self.canvas.width, height: Self.canvas.height)
            .scaleEffect(Self.scale)
            .frame(
                width: Self.canvas.width * Self.scale,
                height: Self.canvas.height * Self.scale
            )
            .frame(maxWidth: .infinity)
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
            // page jumped down, then back when the demo looped.
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.top] }
            .alignmentGuide(.lastTextBaseline) { $0[VerticalAlignment.bottom] }
            .task(id: layoutKey) { await runDemo() }
    }

    @ViewBuilder
    private var demoContent: some View {
        let layout = layout
        ZStack {
            VStack(spacing: 0) {
                if layout.top {
                    RecordingOverlayView(state: mock)
                        .frame(height: RecordingOverlayView.hostHeight)
                }
                Spacer(minLength: 0)
                if let bottom = layout.bottom {
                    PanelOverlayView(state: mock, pill: bottom.pill, bubbleEnabled: bottom.bubble)
                        .frame(height: PanelOverlayView.hostSize.height)
                        .id(layoutKey)
                }
            }
            if layout.isEmpty {
                Text("Nothing is shown while recording")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.35), in: Capsule())
            }
        }
    }

    private func runDemo() async {
        mock.phase = .recording
        mock.audioLevel = 0
        mock.partialText = ""
        mock.supportsLivePreview = showLivePreview

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

            guard showLivePreview else { continue }

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
    InterfacePage()
        .environment(Preferences.shared)
        .environment(ModelManager.shared)
        .frame(width: 500, height: 700)
}
