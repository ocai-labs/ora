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
//  ## API contract
//
//  Three operations with deliberately different semantics — see
//  `docs/2026-04-09-m6-dictation-coordinator-design.md` § Overlay API
//  contract for the full table.
//
//   - `show(phase:)`  : create the panel + set initial phase. **No-op
//                       if a panel already exists** (will not even
//                       update state.phase). First-show only.
//   - `state.phase`   : live mutation while the panel is on screen.
//                       Triggers SwiftUI to re-render.
//   - `hide()`        : close the panel, reset audioLevel, set
//                       state.phase = .done as housekeeping.
//
//  Coordinator code MUST go through the `present(_)` / `dismiss()`
//  helpers in DictationCoordinator rather than calling these directly.
//

import AppKit
import SwiftUI

@MainActor
final class RecordingOverlayController {
    private var panel: NSPanel?
    let state = RecordingOverlayState()

    /// Fired when the user clicks the overlay's cancel affordance.
    /// Wired by DictationCoordinator.start() to coordinator.cancel().
    var onCancel: (() -> Void)?

    /// Fixed panel width for the pill style, wide enough for the
    /// longest error pill. The panel background is transparent so the
    /// extra width is invisible; the SwiftUI capsule centers itself
    /// inside. (The panel style uses PanelOverlayView.hostSize.)
    private static let panelWidth: CGFloat = 320

    /// Gap between the panel-style card's bottom edge and
    /// visibleFrame.minY — clears the Dock's top edge.
    private static let panelBottomMargin: CGFloat = 60

    /// True iff the NSPanel currently exists. Used by
    /// DictationCoordinator.present(_) to pick between show(phase:)
    /// and direct state.phase mutation. M6 addition (not in the
    /// original whisper port).
    var isShowing: Bool { panel != nil }

    func show(phase: OverlayPhase = .recording) {
        guard panel == nil else { return }

        state.phase = phase

        // Style is sampled just-in-time at show(), like model/device
        // resolution — changing the preference mid-dictation only
        // affects the next session.
        let style = Preferences.shared.overlayStyle
        let onCancel: () -> Void = { [weak self] in
            self?.onCancel?()
        }

        let hosting: NSHostingView<AnyView>
        let panelSize: NSSize
        switch style {
        case .pill:
            hosting = NSHostingView(rootView: AnyView(
                RecordingOverlayView(state: state, onCancel: onCancel)
            ))
            panelSize = NSSize(width: Self.panelWidth, height: hosting.fittingSize.height)
        case .panel:
            // Full-form size up front; the SwiftUI card expands inside
            // the transparent panel, bottom-anchored. The NSPanel never
            // resizes (spec §5.4).
            hosting = NSHostingView(rootView: AnyView(
                PanelOverlayView(state: state, onCancel: onCancel)
            ))
            panelSize = PanelOverlayView.hostSize
        }
        hosting.frame = NSRect(origin: .zero, size: panelSize)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // NSPanel defaults to isReleasedWhenClosed = true for
        // programmatically created panels; close() would then release
        // the object behind ARC's back while self.panel still holds a
        // reference — an intermittent over-release on every dictation.
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = false
        panel.contentView = hosting

        // Position on the screen where the user's mouse cursor is,
        // not NSScreen.main (which may point at the primary display
        // when the user is working on an external monitor).
        let screen = Self.screenWithMouseCursor() ?? NSScreen.main
        if let screen {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - panelSize.width / 2
            let y: CGFloat
            switch style {
            case .pill:
                // Top of the screen, as ever.
                y = screenFrame.maxY - 50
            case .panel:
                // Bottom of the screen, card bottom ~60 pt above
                // visibleFrame.minY. The hosting view extends
                // bottomInset below the card (shadow slack), so shift
                // the panel origin down by that amount.
                y = screenFrame.minY + Self.panelBottomMargin - PanelOverlayView.bottomInset
            }
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFront(nil)
        self.panel = panel
    }

    func hide() {
        panel?.close()
        panel = nil
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

    // MARK: - Screen detection

    /// Returns the screen containing the current mouse cursor position.
    private static func screenWithMouseCursor() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
    }
}
