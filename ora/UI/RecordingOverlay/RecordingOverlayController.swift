//
//  RecordingOverlayController.swift
//  ora
//
//  AppKit NSPanel host for the dictation overlay. Ported from the
//  prior whisper project, with one M6 addition: an `isShowing`
//  accessor so DictationCoordinator can decide between
//  show(phase:) (panel creator, no-op if already up) and direct
//  state.phase mutation (live update on an existing panel).
//
//  Up to two panels per dictation — a top one (the pill under the menu
//  bar) and a bottom one (pill and/or live transcription bubble, clear
//  of the Dock) — chosen by OverlayLayout from the Interface settings.
//  When the settings call for nothing visible, show(phase:) creates no
//  panel (isShowing stays false); an error phase later still creates a
//  pill, so failures are never invisible.
//
//  ## API contract
//
//  Three operations with deliberately different semantics — see
//  `docs/2026-04-09-m6-dictation-coordinator-design.md` § Overlay API
//  contract for the full table.
//
//   - `show(phase:)`  : create the panel(s) + set initial phase. **No-op
//                       if a panel already exists** (will not even
//                       update state.phase). First-show only.
//   - `state.phase`   : live mutation while the panel is on screen.
//                       Triggers SwiftUI to re-render.
//   - `hide()`        : close the panel(s), reset audioLevel, set
//                       state.phase = .done as housekeeping.
//
//  Coordinator code MUST go through the `present(_)` / `dismiss()`
//  helpers in DictationCoordinator rather than calling these directly.
//

import AppKit
import SwiftUI

@MainActor
final class RecordingOverlayController {
    private var topPanel: NSPanel?
    private var bottomPanel: NSPanel?
    let state = RecordingOverlayState()

    /// Fired when the user clicks the overlay's cancel affordance.
    /// Wired by DictationCoordinator.start() to coordinator.cancel().
    var onCancel: (() -> Void)?

    /// Fixed width for the top pill panel, wide enough for the longest
    /// error pill. The panel background is transparent so the extra
    /// width is invisible; the SwiftUI capsule centers itself inside.
    /// (The bottom panel uses PanelOverlayView.hostSize.)
    private static let topPanelWidth: CGFloat = 320

    /// Gap between the bottom panel's lowest visible element (pill or
    /// bubble) and visibleFrame.minY — clears the Dock's top edge.
    private static let panelBottomMargin: CGFloat = 60

    /// True iff at least one overlay NSPanel currently exists. Used by
    /// DictationCoordinator.present(_) to pick between show(phase:)
    /// and direct state.phase mutation.
    var isShowing: Bool { topPanel != nil || bottomPanel != nil }

    func show(phase: OverlayPhase = .recording) {
        guard !isShowing else { return }

        state.phase = phase

        // Settings are sampled just-in-time at show(), like model/device
        // resolution — changing them mid-dictation only affects the next
        // session. `supportsLivePreview` was set by the coordinator on
        // `.starting`, before the first show.
        let preferences = Preferences.shared
        let layout = OverlayLayout(
            showPill: preferences.showRecordingPill,
            position: preferences.pillPosition,
            showLivePreview: preferences.showLivePreview,
            phase: phase,
            modelSupportsLivePreview: state.supportsLivePreview
        )
        guard !layout.isEmpty else { return }

        let onCancel: () -> Void = { [weak self] in
            self?.onCancel?()
        }
        // Position on the screen where the user's mouse cursor is,
        // not NSScreen.main (which may point at the primary display
        // when the user is working on an external monitor).
        let screenFrame = (Self.screenWithMouseCursor() ?? NSScreen.main)?.visibleFrame

        if layout.top {
            let size = NSSize(width: Self.topPanelWidth, height: RecordingOverlayView.hostHeight)
            let panel = Self.makePanel(
                rootView: AnyView(RecordingOverlayView(state: state, onCancel: onCancel)),
                size: size
            )
            if let screenFrame {
                // Panel flush with the top of the visible frame; the
                // pill sits RecordingOverlayView.topInset (12pt) below
                // it, i.e. just under the menu bar.
                panel.setFrameOrigin(NSPoint(
                    x: screenFrame.midX - size.width / 2,
                    y: screenFrame.maxY - size.height))
            }
            panel.orderFront(nil)
            topPanel = panel
        }

        if let bottom = layout.bottom {
            // Full-form size up front; the SwiftUI content grows inside
            // the transparent panel, bottom-anchored. The NSPanel never
            // resizes (spec §5.4).
            let size = PanelOverlayView.hostSize
            let panel = Self.makePanel(
                rootView: AnyView(PanelOverlayView(
                    state: state,
                    pill: bottom.pill,
                    bubbleEnabled: bottom.bubble,
                    onCancel: onCancel)),
                size: size
            )
            if let screenFrame {
                // Lowest element's bottom ~60 pt above visibleFrame.minY.
                // The hosting view extends bottomInset below it (shadow
                // slack), so shift the panel origin down by that amount.
                panel.setFrameOrigin(NSPoint(
                    x: screenFrame.midX - size.width / 2,
                    y: screenFrame.minY + Self.panelBottomMargin - PanelOverlayView.bottomInset))
            }
            panel.orderFront(nil)
            bottomPanel = panel
        }
    }

    func hide() {
        topPanel?.close()
        topPanel = nil
        bottomPanel?.close()
        bottomPanel = nil
        state.phase = .done
        state.audioLevel = 0
        // Stale hover from the previous session would flash the cancel
        // control on the next show() — the pill reappears at the same
        // screen position, so the cursor is often still "over" it and
        // `.onHover(false)` never fires.
        state.isCancelHovered = false
        // Stale partial text from the previous dictation must not flash
        // in the panel on the next show().
        state.partialText = ""
        state.supportsLivePreview = false
    }

    // MARK: - Panel

    private static func makePanel(rootView: AnyView, size: NSSize) -> NSPanel {
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // NSPanel defaults to isReleasedWhenClosed = true for
        // programmatically created panels; close() would then release
        // the object behind ARC's back while the controller still holds
        // a reference — an intermittent over-release on every dictation.
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = false
        // No appearance of its own: the panel inherits NSApp.appearance,
        // which AppearanceController sets from the Appearance setting,
        // and re-renders live when it changes — so the glass and its
        // foreground follow System / Light / Dark.
        panel.appearance = nil
        panel.contentView = hosting
        return panel
    }

    // MARK: - Screen detection

    /// Returns the screen containing the current mouse cursor position.
    private static func screenWithMouseCursor() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
    }
}
