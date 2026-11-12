//
//  RecordingOverlayView.swift
//  ora
//
//  Floating "pill" overlay shown during dictation. Ported from the
//  prior whisper project. Three visual modes:
//
//   - Recording: animated waveform driven by `state.audioLevel` (0...1)
//   - Transcribing: 3-dot breathing indicator
//   - Error: icon + short text in a colored pill (red for permission
//     errors, orange for generic)
//
//  The view is a pure binding to `RecordingOverlayState` — it has no
//  control logic. The `RecordingOverlayController` owns the NSPanel
//  and drives the state.
//

import SwiftUI

// MARK: - State

enum OverlayPhase: Equatable {
    case recording
    case transcribing
    case done                   // set by RecordingOverlayController.hide() as housekeeping
    case errorNoMic
    case errorNoAccessibility
    case errorNoModel
    case errorGeneric(String)
}

@Observable
final class RecordingOverlayState {
    var phase: OverlayPhase = .recording
    var audioLevel: Float = 0.0
    var isCancelHovered: Bool = false

    /// Live partial transcript for the panel style. Written by
    /// DictationCoordinator's preview loop (full-text replacement each
    /// update), read by PanelOverlayView. Empty when no preview is
    /// running; reset by hide().
    var partialText: String = ""

    /// Whether the current dictation's model can produce live partials.
    /// Set by the coordinator at show time. The panel renders compact
    /// (pill-like, single line) while false or until the first partial
    /// arrives — see spec §5.4.
    var supportsLivePreview: Bool = false
}

// MARK: - Waveform

struct WaveformBar: View {
    let amplitude: CGFloat
    var width: CGFloat = 3
    var minHeight: CGFloat = 2
    var maxHeight: CGFloat = 20

    var body: some View {
        Capsule()
            .fill(.white)
            .frame(width: width, height: minHeight + (maxHeight - minHeight) * amplitude)
    }
}

struct WaveformView: View {
    let audioLevel: Float
    // Defaults match the original pill rendering; PanelOverlayView passes
    // smaller metrics for the compact in-card waveform.
    var barWidth: CGFloat = 3
    var barSpacing: CGFloat = 2.5
    var minBarHeight: CGFloat = 2
    var maxBarHeight: CGFloat = 20

    private static let barCount = 9
    private static let multipliers: [CGFloat] = [0.35, 0.55, 0.75, 0.9, 1.0, 0.9, 0.75, 0.55, 0.35]

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                WaveformBar(
                    amplitude: barAmplitude(for: index),
                    width: barWidth,
                    minHeight: minBarHeight,
                    maxHeight: maxBarHeight
                )
                .animation(
                    .interpolatingSpring(stiffness: 600, damping: 28),
                    value: audioLevel
                )
            }
        }
        .frame(height: maxBarHeight)
    }

    private func barAmplitude(for index: Int) -> CGFloat {
        let level = CGFloat(audioLevel)
        return min(level * Self.multipliers[index], 1.0)
    }
}

// MARK: - Dots

struct DotsView: View {
    @State private var activeDot = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.white.opacity(activeDot == index ? 0.9 : 0.25))
                    .frame(width: 4.5, height: 4.5)
                    .animation(.easeInOut(duration: 0.4), value: activeDot)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { break }
                activeDot = (activeDot + 1) % 3
            }
        }
    }
}

// MARK: - Error content

struct OverlayErrorContent: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

// MARK: - Pill overlay

/// Top-of-screen pill style: just the shared OraPill, 12pt below the
/// top of the panel (RecordingOverlayController puts the panel flush
/// with the top of the visible frame, so the pill sits 12pt under the
/// menu bar — same as the TS version's TOP_MARGIN). The rest of the
/// fixed-height panel is transparent room for the error pill and the
/// shadow.
struct RecordingOverlayView: View {
    var state: RecordingOverlayState
    /// Kept for RecordingOverlayController's API. The pill no longer has
    /// a hover ×: cancelling is ESC only, as in the TypeScript version.
    var onCancel: (() -> Void)? = nil

    static let topInset: CGFloat = 12
    static let hostHeight: CGFloat = 76

    var body: some View {
        OraPill(phase: state.phase, audioLevel: state.audioLevel)
            .padding(.top, Self.topInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
