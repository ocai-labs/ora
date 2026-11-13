//
//  OraPill.swift
//  ora
//
//  The dictation pill, matched to the TypeScript/Electron Ora's pill
//  (src/renderer/overlay/Pill.tsx + src/core/dictation/waveform.ts),
//  which itself follows the Codex desktop global-dictation capsule:
//
//   - recording / transcribing: a 72×30 capsule. Recording draws 6
//     bars; transcribing swaps them for a spinner. Same size in both,
//     only content changes.
//   - error: grows to fit one short label (h 32).
//   - no hover ×: cancelling is ESC only, as in the TS version — a
//     72pt capsule has no room for a control, and the × used to shove
//     the waveform sideways.
//
//  Shared by every overlay layout (top pill, bottom pill, bottom
//  bubble), so they never drift apart again.
//
//  Surface (`oraOverlaySurface`, also used by the preview bubble):
//  macOS 26+ uses native Liquid Glass (`.glassEffect(.regular)`),
//  untinted for Automatic or tinted with the user's colour at the
//  chosen strength (Settings → Interface → Overlay Glass). It follows
//  the app's Appearance (the NSPanel inherits NSApp.appearance), so it
//  is light glass in Light mode and dark glass in Dark mode. Older
//  systems get a blurred material with the tint overlaid. Note that
//  over other apps' windows — where this overlay always floats — macOS
//  renders Liquid Glass as an adaptive blur + tint with no lensing:
//  measured on macOS 27.2, the glass only refracts / rim-lights content
//  inside its own window, whichever API hosts it (`.glassEffect`,
//  `NSGlassEffectView`, as content view or not).
//
//  Foreground (bars, spinner, text, error label) comes from the surface
//  via `\.oraOverlayForeground`: the colour scheme's primary for
//  Automatic, or white / black from the tint's luminance once the tint
//  is strong enough to dominate (OverlayTint.prefersLightForeground).
//

import AppKit
import SwiftUI

// MARK: - Waveform model (port of core/dictation/waveform.ts)

/// Numeric model behind the 6-bar waveform. Pure state + math, advanced
/// once per frame by `PillWaveformView`. The constants are hand-tuned
/// "feel" copied from the TS version — compare against it before
/// changing any of them.
///
/// Differences from the old 9-bar bell (one scalar × fixed curve):
/// 1. the level goes through `normalize` (noise floor, gain, ^0.6), so
///    quiet speech is visible and a quiet room is really flat;
/// 2. each bar has its own weight / frequency / phase, so bars don't
///    move in lockstep;
/// 3. fast attack (40 ms), slow release (160 ms);
/// 4. no new level for 300 ms counts as silence, so bars fall back on
///    their own when the level source stops;
/// 5. an opening ripple sweeps left→right over ~0.5 s so the pill
///    says "I'm awake" before the mic produces anything.
final class PillWaveformModel {
    static let barCount = 6

    private static let weights: [Double] = [0.64, 0.88, 1, 1, 0.82, 0.58]
    private static let frequencyBase = 4.6
    private static let frequencyStep = 0.71
    private static let phaseStep = 1.67
    private static let attackSeconds = 0.04
    private static let releaseSeconds = 0.16
    private static let staleSeconds = 0.3
    private static let rippleSpeed = 2.0
    private static let rippleStagger = 0.055
    private static let rippleRise = 0.18
    private static let rippleHoldEnd = 0.23
    private static let rippleFallEnd = 0.53
    private static let maxStepSeconds = 1.0 / 15

    /// Current 0...1 height of each bar, ready to draw.
    private(set) var levels = [Double](repeating: 0, count: barCount)
    private var audio = [Double](repeating: 0, count: barCount)
    private var inputLevel = 0.0
    private var inputTime = -Double.infinity
    private var elapsed = 0.0
    private var lastAdvance: Double?

    /// Raw RMS → 0...1 display level. 0.006 is the noise floor, 0.154
    /// the RMS that reads as full scale, ^0.6 lifts weak signals.
    static func normalize(rms: Double) -> Double {
        pow(min(1, max(0, rms - 0.006) / 0.154), 0.6)
    }

    /// Feed an already-normalized level. `now` decides when it goes stale.
    func receive(_ level: Double, now: Double) {
        guard level.isFinite else { return }
        inputLevel = min(1, max(0, level))
        inputTime = now
    }

    /// Advance to `now`. Frames closer than ~1/30 s are skipped by the
    /// caller's TimelineView; a long gap (panel hidden) is capped so the
    /// animation never jumps.
    func advance(now: Double, reducedMotion: Bool) {
        let dt = lastAdvance.map { now - $0 } ?? 0
        lastAdvance = now
        let step = min(max(dt, 0), Self.maxStepSeconds)
        elapsed += step
        let input = now - inputTime <= Self.staleSeconds ? inputLevel : 0

        for i in 0..<Self.barCount {
            let wobble = reducedMotion
                ? 0.8
                : 0.72 + 0.28 * sin(elapsed * (Self.frequencyBase + Self.frequencyStep * Double(i)) + Self.phaseStep * Double(i))
            let target = min(max(input * Self.weights[i] * wobble, 0), 1)
            let current = audio[i]
            let tau = target > current ? Self.attackSeconds : Self.releaseSeconds
            let next = current + (target - current) * (1 - exp(-step / tau))
            audio[i] = next
            levels[i] = max(next, reducedMotion ? 0 : Self.ripple(Self.rippleSpeed * elapsed - Self.rippleStagger * Double(i)))
        }
    }

    /// Ripple height on one bar at its own relative time `a`: raised-
    /// cosine rise, short hold, raised-cosine fall.
    private static func ripple(_ a: Double) -> Double {
        if a < 0 { return 0 }
        if a < rippleRise { return 0.5 - 0.5 * cos(.pi * a / rippleRise) }
        if a < rippleHoldEnd { return 1 }
        if a < rippleFallEnd {
            return 0.5 + 0.5 * cos(.pi * (a - rippleHoldEnd) / (rippleFallEnd - rippleHoldEnd))
        }
        return 0
    }
}

// MARK: - Waveform view

/// 6 bars, 2pt wide on a 5pt pitch (27pt group), centred in a 16pt-tall
/// canvas, drawn per frame at ~30 fps. One model instance lives as long
/// as the view, so the opening ripple starts the moment the pill
/// appears and isn't restarted when the mic comes up.
struct PillWaveformView: View {
    /// RecordingOverlayState.audioLevel — the recorder's `min(1, rms × 8)`.
    let audioLevel: Float

    @State private var model = PillWaveformModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.oraOverlayForeground) private var foreground

    private static let barWidth: CGFloat = 2
    private static let barPitch: CGFloat = 5
    private static let groupWidth = barPitch * CGFloat(PillWaveformModel.barCount) - (barPitch - barWidth)
    private static let minBar: CGFloat = 3
    private static let maxBar: CGFloat = 20

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { context, size in
                model.advance(now: timeline.date.timeIntervalSinceReferenceDate, reducedMotion: reduceMotion)
                let left = (size.width - Self.groupWidth) / 2
                let top = min(size.height, Self.maxBar)
                for (i, level) in model.levels.enumerated() {
                    let h = Self.minBar + CGFloat(level) * (top - Self.minBar)
                    let rect = CGRect(
                        x: left + CGFloat(i) * Self.barPitch,
                        y: (size.height - h) / 2,
                        width: Self.barWidth,
                        height: h)
                    context.fill(Path(roundedRect: rect, cornerRadius: Self.barWidth / 2), with: .color(foreground.opacity(0.9)))
                }
            }
        }
        .frame(height: 16)
        .onAppear { feed(audioLevel) }
        .onChange(of: audioLevel) { _, level in feed(level) }
    }

    /// The recorder hands over `min(1, rms × 8)`; undo the gain to get
    /// RMS back for the TS normalization curve. (Loud speech clips at
    /// rms 0.125 → ~0.86 of full height; close enough not to rewire the
    /// recorder's callback.)
    private func feed(_ level: Float) {
        let rms = Double(level) / 8
        model.receive(PillWaveformModel.normalize(rms: rms), now: Date().timeIntervalSinceReferenceDate)
    }
}

// MARK: - Spinner

/// Stand-in for lucide's LoaderCircle + animate-spin: a 3/4 ring,
/// 14pt, foreground/70%, one turn per second.
struct PillSpinner: View {
    @State private var spinning = false
    @Environment(\.oraOverlayForeground) private var foreground

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(foreground.opacity(0.7), style: StrokeStyle(lineWidth: 1.75, lineCap: .round))
            .frame(width: 12, height: 12)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
            .frame(width: 14, height: 14)
            .onAppear { spinning = true }
    }
}

// MARK: - Pill

struct OraPill: View {
    let phase: OverlayPhase
    let audioLevel: Float

    @State private var appeared = false

    private var isError: Bool { phase.isError }

    /// Recording and done share one key, so the waveform (and its
    /// opening ripple) isn't remounted for a state that changes nothing
    /// visible.
    private var contentKey: String {
        switch phase {
        case .recording, .done: return "recording"
        case .transcribing: return "transcribing"
        default: return "error"
        }
    }

    var body: some View {
        content
            .id(contentKey)
            .transition(.opacity.animation(.easeOut(duration: 0.18)))
            .padding(.horizontal, 8)
            // Recording / transcribing: fixed 72×30. Error: hugs its
            // one-line label (the label is fixedSize, never truncated).
            .frame(width: isError ? nil : 72, height: isError ? 32 : 30)
            .oraOverlaySurface(RoundedRectangle(cornerRadius: isError ? 16 : 15, style: .continuous))
            // Fade in only, no movement: it coincides with the panel
            // ordering front, and any offset reads as a jolt.
            .opacity(appeared ? 1 : 0)
            .onAppear {
                withAnimation(.easeOut(duration: 0.14)) { appeared = true }
            }
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .recording, .done:
            PillWaveformView(audioLevel: audioLevel)
        case .transcribing:
            PillSpinner()
        case .errorNoMic:
            PillErrorContent(icon: "mic.slash.fill", color: .red, text: "Access Not Granted")
        case .errorNoAccessibility:
            PillErrorContent(icon: "hand.raised.fill", color: .red, text: "Accessibility Off")
        case .errorNoModel:
            PillErrorContent(icon: "exclamationmark.triangle.fill", color: .orange, text: "No Model")
        case .errorGeneric(let message):
            PillErrorContent(icon: "exclamationmark.triangle.fill", color: .orange, text: message)
        }
    }
}

/// Icon + one short label, never wrapped or truncated (a half sentence
/// is worse than spilling past the edge).
private struct PillErrorContent: View {
    let icon: String
    let color: Color
    let text: String

    @Environment(\.oraOverlayForeground) private var foreground

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

// MARK: - Surface

extension EnvironmentValues {
    /// Foreground for overlay content (waveform, spinner, text), set by
    /// `oraOverlaySurface` from the glass tint and colour scheme.
    @Entry var oraOverlayForeground: Color = .white

    /// True inside the Settings demo canvas: the pre-macOS 26 blur
    /// samples the demo's own backdrop instead of whatever is behind the
    /// Settings window.
    @Entry var oraOverlayBlendsWithinWindow: Bool = false
}

/// The overlay glass settings, resolved for drawing.
struct OverlayGlassStyle {
    /// nil = Automatic (untinted glass).
    var tint: Color?
    var tintLuminance: Double?
    var strength: Double

    @MainActor
    static func current(_ preferences: Preferences = .shared) -> OverlayGlassStyle {
        guard let hex = preferences.overlayTintHex,
              let rgb = OverlayTint.components(fromHex: hex) else {
            return OverlayGlassStyle(tint: nil, tintLuminance: nil, strength: preferences.overlayTintStrength)
        }
        return OverlayGlassStyle(
            tint: Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue),
            tintLuminance: OverlayTint.relativeLuminance(red: rgb.red, green: rgb.green, blue: rgb.blue),
            strength: preferences.overlayTintStrength)
    }

    func foreground(isDark: Bool) -> Color {
        OverlayTint.prefersLightForeground(tintLuminance: tintLuminance, strength: strength, isDark: isDark)
            ? .white : .black
    }
}

extension View {
    /// The pill / bubble surface. See the file header for what the
    /// glass does (and doesn't) look like over other apps.
    func oraOverlaySurface<S: InsettableShape>(_ shape: S) -> some View {
        modifier(OraOverlaySurface(shape: shape))
    }
}

private struct OraOverlaySurface<S: InsettableShape>: ViewModifier {
    let shape: S

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.oraOverlayBlendsWithinWindow) private var blendsWithinWindow

    func body(content: Content) -> some View {
        // Reads Preferences.shared inside body, so Observation re-renders
        // the overlay (and the Settings demo) when the tint changes.
        let glass = OverlayGlassStyle.current()
        let foreground = glass.foreground(isDark: colorScheme == .dark)
        let styled = content
            .environment(\.oraOverlayForeground, foreground)
            .foregroundStyle(foreground)
        if #available(macOS 26, *) {
            // Native Liquid Glass. No extra fill, shadow or
            // compositingGroup — the glass brings its own depth, and
            // flattening offscreen can break its backdrop sampling.
            styled.glassEffect(Self.glass(glass), in: shape)
        } else {
            styled
                .background {
                    ZStack {
                        OverlayBlurView(blendsWithinWindow: blendsWithinWindow)
                        if let tint = glass.tint {
                            Rectangle().fill(tint.opacity(glass.strength))
                        }
                    }
                    .clipShape(shape)
                }
                // Hairline rim so the blur still reads over a backdrop
                // of the same brightness.
                .overlay(shape.strokeBorder(foreground.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.15), radius: 7, x: 0, y: 5)
        }
    }

    @available(macOS 26, *)
    private static func glass(_ style: OverlayGlassStyle) -> Glass {
        guard let tint = style.tint else { return .regular }
        return .regular.tint(tint.opacity(style.strength))
    }
}

/// Pre-macOS 26 backdrop: a vibrancy blur that follows the effective
/// appearance (light in Light mode, dark in Dark mode).
private struct OverlayBlurView: NSViewRepresentable {
    var blendsWithinWindow: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.state = .active
        view.blendingMode = blendsWithinWindow ? .withinWindow : .behindWindow
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.blendingMode = blendsWithinWindow ? .withinWindow : .behindWindow
    }
}
