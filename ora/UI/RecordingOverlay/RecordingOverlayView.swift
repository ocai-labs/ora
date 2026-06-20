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

struct RecordingOverlayView: View {
    var state: RecordingOverlayState
    var onCancel: (() -> Void)? = nil

    var body: some View {
        // onHover attaches to the pill itself, BEFORE the frame
        // expansion — on the full-width invisible strip it fired while
        // the cursor was in the transparent margin beside the pill,
        // showing the × with nothing visually under the cursor.
        pill
            .onHover { hovering in
                state.isCancelHovered = hovering
            }
            .frame(maxWidth: .infinity)
    }

    /// Cancel affordance shows only during recording / transcribing and
    /// only while the user is hovering the pill. A small trailing × in
    /// a circle, clickable. Visual polish (animations, slide-out)
    /// deferred — see spec § 3b.
    private var showsCancelControl: Bool {
        guard state.isCancelHovered else { return false }
        switch state.phase {
        case .recording, .transcribing: return true
        default: return false
        }
    }

    private var pill: some View {
        HStack(spacing: 10) {
            Group {
                switch state.phase {
                case .errorNoMic:
                    OverlayErrorContent(icon: "mic.slash.fill", color: .red, text: "Access Not Granted")
                        .transition(.opacity)
                case .errorNoAccessibility:
                    OverlayErrorContent(icon: "hand.raised.fill", color: .red, text: "Accessibility Off")
                        .transition(.opacity)
                case .errorNoModel:
                    OverlayErrorContent(icon: "exclamationmark.triangle.fill", color: .orange, text: "No Model")
                        .transition(.opacity)
                case .errorGeneric(let message):
                    OverlayErrorContent(icon: "exclamationmark.triangle.fill", color: .orange, text: message)
                        .transition(.opacity)
                case .transcribing:
                    DotsView()
                        .transition(.opacity)
                case .recording, .done:
                    WaveformView(audioLevel: state.audioLevel)
                        .transition(.opacity)
                }
            }

            if showsCancelControl {
                Button {
                    onCancel?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(Color.black)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 4)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: state.phase)
        .animation(.easeInOut(duration: 0.12), value: showsCancelControl)
    }
}
