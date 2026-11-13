//
//  PanelOverlayView.swift
//  ora
//
//  Bottom-of-screen overlay: the live transcription bubble and/or the
//  pill. Which pieces it draws comes from OverlayLayout (Settings →
//  Interface): with the pill at the bottom it's the classic stack below;
//  with the pill at the top it's the bubble alone; with the pill hidden
//  the bubble carries a compact inline waveform, and a stand-in pill
//  shows until the first partial (or on errors). The full stack is two
//  separate pieces, bottom-anchored:
//
//   - the pill (OraPill — the same 72×30 capsule as the top style and
//     as the TypeScript Ora), which never moves or resizes while
//     recording;
//   - a bubble ABOVE it holding the live partial. It appears
//     when the first partial arrives (fade + slight rise out of the
//     pill), stays through transcribing so the last partial is visible
//     while the spinner runs, and disappears with the overlay or on any
//     error.
//
//  The bubble has a fixed width, so words streaming in never make it
//  jitter sideways. Its height follows the text one line at a time up
//  to 3 lines, then the text tail-scrolls inside that 3-line window —
//  newest line pinned at the bottom, older lines hard-clipped out the
//  top (no fade, no ScrollView). Text is full-replacement each update,
//  with an inline diff crossfade on the changed tail.
//
//  Like RecordingOverlayView this is a pure binding to
//  RecordingOverlayState — no control logic. The hosting NSPanel is
//  created at full size with a transparent background; everything grows
//  upward inside it, so the NSPanel itself never resizes.
//

import AppKit
import SwiftUI

struct PanelOverlayView: View {
    var state: RecordingOverlayState
    /// How this panel treats the pill — see OverlayLayout.BottomPill.
    var pill: OverlayLayout.BottomPill = .always
    /// Whether the live transcription bubble may appear at all.
    var bubbleEnabled: Bool = true
    /// Kept for RecordingOverlayController's API. The pill no longer has
    /// a hover ×: cancelling is ESC only, as in the TypeScript version.
    var onCancel: (() -> Void)? = nil

    // MARK: - Layout constants

    /// NSPanel content size: room for the 3-line bubble + gap + pill,
    /// plus slack for the shadows and the bubble's entrance overshoot.
    static let hostSize = NSSize(width: 600, height: 168)

    /// Gap between the hosting view's bottom edge and the pill's bottom
    /// edge (shadow room). RecordingOverlayController subtracts this when
    /// positioning so the visible pill bottom sits at its target height.
    static let bottomInset: CGFloat = 16

    private static let bubbleWidth: CGFloat = 420
    private static let bubbleHorizontalPadding: CGFloat = 14
    private static let bubbleVerticalPadding: CGFloat = 10
    private static let bubbleCornerRadius: CGFloat = 14
    private static let bubbleToPillGap: CGFloat = 8
    private static let maxLines: CGFloat = 3
    private static let lineSpacing: CGFloat = 3

    /// Fixed text column width = bubble width minus its padding. The
    /// text always wraps at this width, so the bubble never re-wraps.
    private static let maxTextWidth: CGFloat = bubbleWidth - 2 * bubbleHorizontalPadding

    /// Inline waveform/spinner column used when the pill is hidden
    /// (`.standIn`): the waveform's 27pt bar group plus a gap.
    private static let inlineIndicatorWidth: CGFloat = 27
    private static let inlineIndicatorGap: CGFloat = 10

    private var hasInlineIndicator: Bool { pill == .standIn }

    /// The text column for this layout: the full width, or narrower to
    /// make room for the inline indicator. Still constant for the
    /// lifetime of the view, so text never re-wraps mid-stream.
    private var textColumnWidth: CGFloat {
        hasInlineIndicator
            ? Self.maxTextWidth - Self.inlineIndicatorWidth - Self.inlineIndicatorGap
            : Self.maxTextWidth
    }

    private static let transcriptFont = Font.system(size: 13, weight: .medium, design: .rounded)

    /// Natural (unclipped) height of the partial wrapped at the fixed
    /// column width, with NO line cap. Compared against `cappedHeight` to
    /// decide whether the text genuinely overflows the 3-line window.
    @State private var textNaturalHeight: CGFloat = 0

    /// Height of the SAME partial wrapped at the fixed column width but
    /// capped at `maxLines` (`.lineLimit`). This is the real, per-script
    /// 3-line window height (and the real 1–2-line height while shorter) —
    /// measured from the actual text, so CJK / Thai / any script that
    /// renders taller than Latin is sized correctly. Both the window cap
    /// and the overflow test derive from this, NOT from a Latin sample.
    @State private var cappedHeight: CGFloat = 0

    /// Explicit window height: the real capped height, so the bubble grows
    /// one line at a time (1 → 2 → 3 lines) and then tail-scrolls, so the
    /// bubble always hugs its text (no empty 3rd line). Nil before the
    /// first measurement lands (one
    /// layout pass), letting the frame follow the proposal. Using the real
    /// `cappedHeight` means CJK / taller scripts get their true height.
    private var visibleTextHeight: CGFloat? {
        guard textNaturalHeight > 0, cappedHeight > 0 else { return nil }
        return cappedHeight
    }

    /// True once the text genuinely exceeds the 3-line window — only then
    /// does it bottom-anchor + scroll. Both sides are the SAME text's real
    /// measurement (`cappedHeight` is just the line-capped one), so for
    /// ≤3 lines they're equal and this is false regardless of script; a
    /// 4th line adds a whole line, well past the 1pt rounding buffer. This
    /// is what fixes the CJK false-overflow (was: real height vs a Latin
    /// synthesized 3-line height, which tripped at a full 3 CJK lines).
    private var textOverflows: Bool {
        cappedHeight > 0 && textNaturalHeight > cappedHeight + 1
    }

    // MARK: - Partial diff (inline crossfade)

    /// Per-round diff of the partial against the previous frame.
    /// Everything before `stableCount` (graphemes) is "settled" and
    /// renders with no transition; everything after is the fresh tail
    /// that fades in. `ghost` is the FULL previous text whenever its
    /// tail past `stableCount` differs from the new tail — the ghost
    /// layer shows that outgoing tail fading out in place. Slicing the
    /// OLD text at the NEW boundary is what makes deep revisions work:
    /// a word revised inside settled territory ("I am" → "I'm") still
    /// fades out, instead of popping (the old id-swap snapshot only
    /// covered the previous round's tail). `generation` gives the
    /// fading layers their identity.
    private struct PartialDiff: Equatable {
        var text: String = ""
        var stableCount: Int = 0
        var ghost: String? = nil
        var generation: Int = 0
    }

    @State private var diff = PartialDiff()

    /// Drives the ghost layer's fade-out; reset to 1 (no animation)
    /// and animated to 0 on every round that has a ghost.
    @State private var ghostOpacity: Double = 0

    /// How far the diff boundary may look back for a whitespace when
    /// it lands mid-word (longest English words; CJK has none and
    /// keeps the raw character boundary).
    nonisolated private static let diffLookback = 24

    /// Common-prefix diff between consecutive partials, word-aligned:
    /// when the boundary splits a word ("i scream" → "ice cream"
    /// shares "i scre…"? no — but "transcri…" → "transcription" does),
    /// it snaps back to the word's start so the revised word fades as
    /// a unit. Snapping only happens when a whitespace is found within
    /// the lookback — text without spaces (CJK) keeps the character
    /// boundary instead of re-fading the whole transcript.
    nonisolated private static func diffed(from previous: PartialDiff, to newText: String) -> PartialDiff {
        let old = Array(previous.text)
        let new = Array(newText)
        var common = 0
        while common < old.count, common < new.count, old[common] == new[common] {
            common += 1
        }
        var boundary = common
        // Mid-word boundary: a settled word is being revised/extended.
        // (A pure append after a space leaves new[common] == " " or
        // common at a word start, and skips the snap — appending must
        // not re-fade the last settled word.)
        if common > 0, common < new.count,
           !new[common - 1].isWhitespace, !new[common].isWhitespace {
            var i = common
            var steps = 0
            while i > 0, steps < Self.diffLookback {
                if new[i - 1].isWhitespace {
                    boundary = i
                    break
                }
                i -= 1
                steps += 1
            }
        }
        let newTail = String(new[boundary...])
        let oldTail = String(old[min(boundary, old.count)...])
        let ghost = (!oldTail.isEmpty && oldTail != newTail) ? previous.text : nil
        return PartialDiff(
            text: newText, stableCount: boundary, ghost: ghost,
            generation: previous.generation + 1)
    }


    var body: some View {
        VStack(spacing: Self.bubbleToPillGap) {
            if showsBubble {
                bubble
                    .transition(
                        .opacity
                            .combined(with: .scale(scale: 0.94, anchor: .bottom))
                            .combined(with: .offset(y: 6))
                    )
            }
            if showsPill {
                OraPill(phase: state.phase, audioLevel: state.audioLevel)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: showsBubble)
        .padding(.bottom, Self.bottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        // Line-by-line growth, keyed to the measured heights (committed
        // alongside the visible text), eased with no overshoot.
        // cappedHeight drives growth; textNaturalHeight covers the
        // bottom-anchor flip once the text overflows 3 lines.
        //
        // These MUST sit outside the bottom-aligned frame above, not on
        // the bubble: the bubble's position comes from this bottom-aligned
        // stack. With the animation on the bubble only its size animated
        // while its position snapped to the final value, so on every new
        // line the whole bubble jumped up a full line and then slid its
        // bottom back down onto the pill (measured frame by frame: top
        // -38 px in one frame, bottom recovering over ~0.25 s).
        .animation(.smooth(duration: 0.32), value: cappedHeight)
        .animation(.smooth(duration: 0.32), value: textNaturalHeight)
        // Fresh dictation (coordinator clears the partial on
        // `.starting`): drop the previous sentence's measurements so the
        // next bubble starts from scratch instead of animating down from
        // the old size. Non-empty partials commit via the measurement
        // preferences in transcriptTail, so text and geometry land
        // together.
        .onChange(of: state.partialText) { _, newValue in
            guard newValue.isEmpty else { return }
            textNaturalHeight = 0
            cappedHeight = 0
            diff = PartialDiff()
            ghostOpacity = 0
        }
    }

    /// The bubble shows only while live partials are meaningful: the
    /// model supports preview, at least one partial has arrived, and
    /// we're recording (or transcribing — keep the last partial visible
    /// while the spinner runs). Errors drop it; the pill carries the
    /// error on its own.
    private var showsBubble: Bool {
        guard bubbleEnabled, state.supportsLivePreview, !state.partialText.isEmpty else { return false }
        switch state.phase {
        case .recording, .transcribing: return true
        default: return false
        }
    }

    /// The pill shows always, never (it's in the top panel), or — when
    /// hidden by preference — only while the bubble isn't up, so the
    /// user still sees that recording is on (and errors stay visible).
    private var showsPill: Bool {
        switch pill {
        case .always: return true
        case .never: return false
        case .standIn: return !showsBubble
        }
    }

    // MARK: - Bubble

    private var bubble: some View {
        let shape = RoundedRectangle(cornerRadius: Self.bubbleCornerRadius, style: .continuous)
        return HStack(alignment: .top, spacing: Self.inlineIndicatorGap) {
            if hasInlineIndicator {
                inlineIndicator
            }
            transcriptTail
        }
            .padding(.horizontal, Self.bubbleHorizontalPadding)
            .padding(.vertical, Self.bubbleVerticalPadding)
            .frame(width: Self.bubbleWidth)
            .oraOverlaySurface(shape)
    }

    /// Compact recording state inside the bubble when there's no pill:
    /// the waveform while recording, the spinner while transcribing,
    /// centred on the first text line.
    @ViewBuilder
    private var inlineIndicator: some View {
        Group {
            if state.phase == .transcribing {
                PillSpinner()
            } else {
                PillWaveformView(audioLevel: state.audioLevel)
            }
        }
        .frame(width: Self.inlineIndicatorWidth, height: 17)
    }

    /// Tail-follow live text in a fixed-width column. The column width is
    /// constant (maxTextWidth), so the text wraps at its final width from
    /// the first frame and never re-wraps mid-stream. The window height
    /// follows the text one line at a time up to 3 lines; while it fits
    /// it is top-aligned, and only once it
    /// overflows does it bottom-anchor and scroll, older lines hard-clip
    /// out the top (`.clipped()`, no fade). No ScrollView — no re-scroll
    /// jumping at 1 Hz replacements; the Text content swaps instantly,
    /// only the bubble's container geometry animates.
    private var transcriptTail: some View {
        // Inline diff crossfade (spec §8 risk 2), mirroring
        // spikes/diff-fade-demo.html mode B exactly:
        //  - settled layer: swaps instantly every round — its visible
        //    glyphs are identical text at identical positions, so
        //    nothing pops and it never dims;
        //  - fresh layer: only the revised/appended tail visible,
        //    fades IN on each round (id-swap; removal is .identity —
        //    fading out is the ghost's job, doubling up would
        //    double-expose the old tail);
        //  - ghost overlay: the previous text sliced at the NEW
        //    boundary, fading OUT in place (handles deep revisions
        //    into settled territory, which the removed fresh layer's
        //    stale boundary cannot cover). Lives in an overlay so its
        //    (old) size never affects the measured geometry.
        // Both layers lay out a full string with the hidden half's
        // runs .clear, so wrapping is pixel-identical. The animations
        // ride on the transition / an explicit opacity state, NOT on
        // the write transaction: a withAnimation write also animated
        // layout and made the block slide in from the bottom-left.
        // (A whole-layer contentTransition crossfade dimmed ALL the
        // text against the black bubble — the flashing "black edges".)
        //
        // Geometry: the column width is constant (maxTextWidth), so the
        // layers always lay out at their final width and never re-wrap.
        // A hidden twin measures the incoming partial's wrapped height at
        // that width; the visible text + diff commit together with that
        // height in the height preference handler, one layout pass after
        // the partial arrives. The clip WINDOW height (outer frame) then
        // animates toward the measured target, revealing freshly wrapped
        // lines as the bar grows rather than letting them spill first.
        ZStack(alignment: .topLeading) {
            partialLayer(text: diff.text, stableCount: diff.stableCount, showsSettled: true)
            partialLayer(text: diff.text, stableCount: diff.stableCount, showsSettled: false)
                .id(diff.generation)
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeInOut(duration: 0.22)),
                    removal: .identity
                ))
        }
        .overlay(alignment: .topLeading) {
            if let ghost = diff.ghost {
                partialLayer(text: ghost, stableCount: diff.stableCount, showsSettled: false)
                    .opacity(ghostOpacity)
                    .allowsHitTesting(false)
            }
        }
        // Fixed column width; the window height is the only thing that
        // moves. Top-aligned while it fits in ≤3 lines (line 1 at top,
        // filling down), bottom-aligned once it overflows so the newest
        // line stays pinned and older lines hard-clip out the top
        // (`.clipped()`, no fade mask).
        .frame(
            width: textColumnWidth,
            height: visibleTextHeight,
            alignment: textOverflows ? .bottomLeading : .topLeading
        )
        .clipped()
        // Hidden measurement twins (uncapped, capped). Grouped
        // into one background so this modifier chain stays short enough
        // for the type-checker.
        .background(measurers)
        // The commit point: the visible text, its diff boundary, and the
        // measured natural height land in ONE transaction (one layout
        // pass after the partial arrives). Plain writes, deliberately NOT
        // withAnimation — the crossfade rides on the transition / the
        // explicit ghostOpacity animation; the body-level
        // .animation(value: textNaturalHeight/cappedHeight) carries the
        // window growth.
        .onPreferenceChange(TranscriptHeightKey.self) { metrics in
            guard !metrics.text.isEmpty else { return }
            textNaturalHeight = metrics.value
            guard metrics.text != diff.text else { return }
            diff = Self.diffed(from: diff, to: metrics.text)
            if diff.ghost != nil {
                // Restart the ghost fade-out: snap to opaque outside
                // any animation, then animate to clear.
                var snap = Transaction()
                snap.disablesAnimations = true
                withTransaction(snap) { ghostOpacity = 1 }
                withAnimation(.easeInOut(duration: 0.22)) { ghostOpacity = 0 }
            }
        }
        .onPreferenceChange(TranscriptCappedHeightKey.self) { metrics in
            guard !metrics.text.isEmpty else { return }
            cappedHeight = metrics.value
        }
    }

    /// Hidden measurement twins, grouped so they never affect layout and
    /// the visible chain stays short enough for the type-checker.
    /// `.hidden()` also keeps them out of accessibility.
    private var measurers: some View {
        ZStack {
            naturalHeightTwin
            cappedHeightTwin
        }
        .hidden()
    }

    /// The partial wrapped at the column width, UNCAPPED → natural height
    /// (full line count). Compared against the capped height to detect
    /// genuine overflow past 3 lines.
    private var naturalHeightTwin: some View {
        Text(state.partialText)
            .font(Self.transcriptFont)
            .lineSpacing(Self.lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: TranscriptHeightKey.self,
                        value: TranscriptMetrics(
                            text: state.partialText,
                            value: proxy.size.height
                        )
                    )
                }
            )
            .frame(width: textColumnWidth, alignment: .topLeading)
    }

    /// The SAME partial, capped at `maxLines` → the real per-script window
    /// height (1/2-line while short, the true 3-line height at 3+ lines,
    /// CJK / taller scripts included).
    private var cappedHeightTwin: some View {
        Text(state.partialText)
            .font(Self.transcriptFont)
            .lineSpacing(Self.lineSpacing)
            .lineLimit(Int(Self.maxLines))
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: TranscriptCappedHeightKey.self,
                        value: TranscriptMetrics(
                            text: state.partialText,
                            value: proxy.size.height
                        )
                    )
                }
            )
            .frame(width: textColumnWidth, alignment: .topLeading)
    }

    /// One layer of the diff stack: a full string as a single
    /// AttributedString with the *other* half's runs set to `.clear`.
    /// Color doesn't affect glyph metrics, so all layers (settled,
    /// fresh, ghost) wrap identically — tails fade exactly where they
    /// belong in the paragraph.
    private func partialLayer(text: String, stableCount: Int, showsSettled: Bool) -> some View {
        var attributed = AttributedString(text)
        // Visible runs carry no colour of their own, so they inherit the
        // overlay surface's foreground (see oraOverlaySurface).
        let visible: Color? = nil
        let boundary = attributed.characters.index(
            attributed.startIndex,
            offsetBy: min(stableCount, attributed.characters.count)
        )
        attributed[attributed.startIndex..<boundary].foregroundColor = showsSettled ? visible : .clear
        attributed[boundary..<attributed.endIndex].foregroundColor = showsSettled ? .clear : visible
        return Text(attributed)
            .font(Self.transcriptFont)
            .lineSpacing(Self.lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One twin's measurement, tagged with the text it was measured from:
/// the tag is what the commit handler uses, so a height is never paired
/// with a different round's text (preferences land a layout pass after
/// the partial that produced them), and it guarantees the preference
/// CHANGES — and so fires — every round even when the metric itself
/// happens to be equal (same-height rewrites).
private struct TranscriptMetrics: Equatable {
    var text = ""
    var value: CGFloat = 0
}

/// Carries the incoming text's natural wrapped height out of the
/// hidden height twin (macOS 14 target — no onGeometryChange yet).
/// Reduce must IGNORE empty contributions: sibling subtrees that
/// never set the key still reduce their defaultValue in, and a plain
/// `value = nextValue()` let that default clobber the twin's real
/// measurement (observed: onPreferenceChange only ever saw ("", 0)).
private struct TranscriptHeightKey: PreferenceKey {
    static let defaultValue = TranscriptMetrics()
    static func reduce(value: inout TranscriptMetrics, nextValue: () -> TranscriptMetrics) {
        let next = nextValue()
        if !next.text.isEmpty { value = next }
    }
}

/// Same as TranscriptHeightKey, but for the maxLines-capped twin — the
/// real per-script window height. Empty contributions ignored for the
/// same reason.
private struct TranscriptCappedHeightKey: PreferenceKey {
    static let defaultValue = TranscriptMetrics()
    static func reduce(value: inout TranscriptMetrics, nextValue: () -> TranscriptMetrics) {
        let next = nextValue()
        if !next.text.isEmpty { value = next }
    }
}
