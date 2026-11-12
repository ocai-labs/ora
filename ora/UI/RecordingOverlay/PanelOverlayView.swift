//
//  PanelOverlayView.swift
//  ora
//
//  Bottom-of-screen "panel" overlay style for dictation with live
//  preview (spec §4 / §5.4). Two forms rendered by the same card:
//
//   - Full: fixed-width card, bottom-anchored, grows only UPWARD.
//     (1) Before the first partial the compact pill shows just the
//     waveform. (2) The first partial expands the card ONCE to a centred,
//     fixed width — a single gentle-overshoot motion — and from then on
//     the width never changes, so there is zero left/right jitter as
//     words stream in. The text spans the full card width ABOVE the
//     waveform, which stays centred in a bottom row at the height it had
//     in the compact pill. The text wraps at its final column from the
//     first frame; the card clips, then reveals it as it grows.
//     (3) Height: the card grows one line at a time up to 3 lines, then
//     the text tail-scrolls inside that 3-line window — the newest line
//     pinned at the bottom (right above the waveform), older lines
//     hard-clipped out the top (no fade). Text is full-replacement each
//     update.
//
//     The text column width is FIXED (= maxTextWidth), so the card never
//     re-wraps mid-stream and we no longer measure single-line ideal
//     width. We measure the partial's wrapped height twice (GeometryReader
//     twins: uncapped, and capped at 3 lines) to size the window and to
//     detect overflow past 3 lines. The card height hugs the resulting
//     window so it (the visible text window) and the card grow on the
//     SAME transaction — a freshly wrapped line is revealed only as the
//     bar grows, never spilling outside it first.
//
//   - Compact: pill-equivalent single line (waveform / dots / error)
//     at the bottom position. Used when the model has no live preview,
//     before the first partial arrives, and for all error phases.
//
//  Like RecordingOverlayView this is a pure binding to
//  RecordingOverlayState — no control logic. The hosting NSPanel is
//  created at full-form size with a transparent background; the card
//  grows/shrinks inside it, bottom-anchored, so the NSPanel itself
//  never resizes.
//

import AppKit
import SwiftUI

struct PanelOverlayView: View {
    var state: RecordingOverlayState
    var onCancel: (() -> Void)? = nil

    // MARK: - Layout constants

    /// NSPanel content size. Wide/tall enough for the expanded card
    /// plus slack so the spring overshoot on expand isn't clipped at
    /// the hosting-view edge.
    static let hostSize = NSSize(width: 600, height: 168)

    /// Gap between the hosting view's bottom edge and the card's bottom
    /// edge (lifts the card off the screen edge and leaves overshoot
    /// room). RecordingOverlayController subtracts this when positioning
    /// so the visible card bottom sits exactly at its target height.
    static let bottomInset: CGFloat = 16

    private static let expandedWidth: CGFloat = 440
    private static let maxLines: CGFloat = 3           // height cap: 3-line window
    private static let lineSpacing: CGFloat = 3        // matches partialLayer / height twin
    private static let compactHeight: CGFloat = 38     // same as the pill

    /// Height of the bottom indicator row in the expanded card — the
    /// default WaveformView's max bar height, so the bars render at the
    /// same size in both forms.
    private static let indicatorRowHeight: CGFloat = 20

    /// Expanded-card paddings. The bottom inset is chosen so the indicator
    /// row's centre sits at compactHeight / 2 above the card's bottom edge
    /// — exactly where the compact pill centres its waveform — so the
    /// waveform doesn't hop when the pill expands (the card is
    /// bottom-anchored, all growth goes upward above it).
    private static let expandedTopPadding: CGFloat = 13
    private static let expandedBottomPadding: CGFloat = (compactHeight - indicatorRowHeight) / 2
    private static let textToIndicatorSpacing: CGFloat = 8

    /// Fixed width of the text column once expanded: the card width minus
    /// horizontal padding (16×2). The text sits above the waveform row and
    /// spans the full card, and it always wraps at this width, so the card
    /// width is constant after the one-time expand.
    private static let maxTextWidth: CGFloat = expandedWidth - 32

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

    /// Explicit window height: the real capped height, so the card grows
    /// one line at a time (1 → 2 → 3 lines) and then tail-scrolls. With
    /// the waveform row directly under the text, the old jump straight to
    /// a 3-line window left an empty line as a visible gap between the
    /// text and the waveform. Nil before the first measurement lands (one
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
        card
            // onHover on the card itself (not the expanded frame) so the
            // × never shows while the cursor is in transparent margin —
            // same rationale as RecordingOverlayView.
            .onHover { hovering in
                state.isCancelHovered = hovering
            }
            .padding(.bottom, Self.bottomInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    // MARK: - Form selection

    /// Full form only while live partials are meaningful: the model
    /// supports preview, at least one partial has arrived, and we're
    /// recording (or transcribing — keep the last partial visible while
    /// the dots spin). Error phases collapse to the compact error pill.
    private var isExpanded: Bool {
        guard state.supportsLivePreview, !state.partialText.isEmpty else { return false }
        switch state.phase {
        case .recording, .transcribing: return true
        default: return false
        }
    }

    /// Same semantics as the pill: × only while hovered and only during
    /// recording / transcribing.
    private var showsCancelControl: Bool {
        guard state.isCancelHovered else { return false }
        switch state.phase {
        case .recording, .transcribing: return true
        default: return false
        }
    }

    // MARK: - Card

    private var card: some View {
        // Text on top, waveform in a centred row underneath. ONE VStack in
        // both forms — the compact pill is just the bottom row on its own —
        // so the indicator keeps its identity across the expand (no
        // container swap that would restart the bar springs / DotsView
        // task). The hosting frame is bottom-anchored, so the waveform row
        // stays put and every bit of height growth (the expand, the 3-line
        // jump) extends upward above it.
        VStack(alignment: .center, spacing: Self.textToIndicatorSpacing) {
            if isExpanded {
                transcriptTail
                    .transition(.opacity)
            }

            // In the compact pill the × sits inline next to the waveform,
            // as before; in the expanded card it moves to the overlay
            // below so it can't push the centred waveform sideways (and
            // can't be pushed past the clipped right edge, which is what
            // happened with the old fixed-width HStack).
            HStack(spacing: 12) {
                indicator
                if showsCancelControl && !isExpanded {
                    cancelButton
                }
            }
            .frame(height: isExpanded ? Self.indicatorRowHeight : nil)
        }
        .padding(.horizontal, 16)
        .padding(.top, isExpanded ? Self.expandedTopPadding : 0)
        .padding(.bottom, isExpanded ? Self.expandedBottomPadding : 0)
        // Fixed expanded width, content bottom-centred; the card clips its
        // content and reveals it as the width animates out. Compact hugs
        // the lone indicator row.
        .frame(
            width: isExpanded ? Self.expandedWidth : nil,
            height: isExpanded ? nil : Self.compactHeight,
            alignment: isExpanded ? .bottom : .center
        )
        .overlay(alignment: .bottomTrailing) {
            if showsCancelControl && isExpanded {
                cancelButton
                    .frame(height: Self.indicatorRowHeight)
                    .padding(.trailing, 12)
                    .padding(.bottom, Self.expandedBottomPadding)
            }
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(
            cornerRadius: isExpanded ? 18 : Self.compactHeight / 2,
            style: .continuous
        ))
        // The one-time expand (compact pill → fixed-width card) rides a
        // gentle-overshoot spring — the Apple "easeOutBack" feel. After
        // that the width never changes again.
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: isExpanded)
        // Line-by-line growth: keyed to the measured natural height (which the
        // height twin commits alongside the visible text), eased with no
        // overshoot so the bar settles cleanly into the new window. The
        // window height rides this same transaction, so a freshly wrapped
        // line is revealed only as the bar grows — never spilling first.
        // Window growth is driven by cappedHeight (real per-script 3-line
        // height); textNaturalHeight covers the bottom-anchor flip. Key
        // both so the height eases whichever measurement moves it.
        .animation(.smooth(duration: 0.42), value: cappedHeight)
        .animation(.smooth(duration: 0.42), value: textNaturalHeight)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: state.phase)
        .animation(.easeInOut(duration: 0.12), value: showsCancelControl)
        // Fresh dictation (coordinator clears the partial on
        // `.starting`): drop the previous sentence's measurements so
        // the next expansion starts from scratch instead of animating
        // down from the old card size. No transition for the reset —
        // the tail view is already gone (isExpanded is false).
        // Non-empty partials commit via the measurement preferences
        // in transcriptTail, so text and geometry land together.
        .onChange(of: state.partialText) { _, newValue in
            guard newValue.isEmpty else { return }
            textNaturalHeight = 0
            cappedHeight = 0
            diff = PartialDiff()
            ghostOpacity = 0
        }
    }

    private var cancelButton: some View {
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

    /// Bottom row: phase parity with the pill — waveform while
    /// recording, dots while transcribing, error content otherwise.
    /// Same waveform metrics in both forms, so the bars don't change
    /// size (or swap views) when the pill expands.
    @ViewBuilder
    private var indicator: some View {
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

    /// Tail-follow live text in a fixed-width column. The column width is
    /// constant (maxTextWidth), so the text wraps at its final width from
    /// the first frame and never re-wraps mid-stream. The window height
    /// follows the text one line at a time up to 3 lines; while it fits
    /// it is top-aligned, and only once it
    /// overflows does it bottom-anchor and scroll, older lines hard-clip
    /// out the top (`.clipped()`, no fade). No ScrollView — no re-scroll
    /// jumping at 1 Hz replacements; the Text content swaps instantly,
    /// only the card's container geometry animates.
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
        // text against the black card — the flashing "black edges".)
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
            width: Self.maxTextWidth,
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
        // explicit ghostOpacity animation; the card-level
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
            .frame(width: Self.maxTextWidth, alignment: .topLeading)
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
            .frame(width: Self.maxTextWidth, alignment: .topLeading)
    }

    /// One layer of the diff stack: a full string as a single
    /// AttributedString with the *other* half's runs set to `.clear`.
    /// Color doesn't affect glyph metrics, so all layers (settled,
    /// fresh, ghost) wrap identically — tails fade exactly where they
    /// belong in the paragraph.
    private func partialLayer(text: String, stableCount: Int, showsSettled: Bool) -> some View {
        var attributed = AttributedString(text)
        let visible = Color.white.opacity(0.95)
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
