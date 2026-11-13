//
//  OverlayLayout.swift
//  ora
//
//  Pure mapping from the Interface preferences (show pill, pill
//  position, show live transcription) to which overlay panels exist and
//  what each one draws. RecordingOverlayController resolves it once per
//  show(); the Interface page's demo canvas uses the same mapping so
//  the preview matches what dictation will actually look like.
//
//   pill  | position | bubble | result
//   ------+----------+--------+-------------------------------------------
//   on    | bottom   | on     | bottom: bubble above the pill (the old Panel)
//   on    | bottom   | off    | bottom: pill alone, clear of the Dock
//   on    | top      | on     | top: pill; bottom: bubble only
//   on    | top      | off    | top: pill (the old Pill style)
//   off   | —        | on     | bottom: bubble with an inline waveform; a
//         |          |        | stand-in pill until the first partial
//   off   | —        | off    | nothing — except errors, which still get a
//         |          |        | pill at `position` so failures are visible
//

import Foundation

struct OverlayLayout: Equatable {
    /// How the bottom panel treats the pill.
    enum BottomPill: Equatable {
        /// Always draw the pill (bubble, if any, stacks above it).
        case always
        /// Never draw a pill — it lives in the top panel.
        case never
        /// The pill is hidden by preference: draw it only while the
        /// bubble isn't showing (before the first partial, unsupported
        /// model, errors); the bubble carries its own compact waveform.
        case standIn
    }

    struct Bottom: Equatable {
        var pill: BottomPill
        /// Whether the live transcription bubble may appear.
        var bubble: Bool
    }

    var showPill: Bool
    var position: PillPosition
    var showLivePreview: Bool

    /// A top panel holding the pill.
    var top: Bool
    /// A bottom panel, or nil for none.
    var bottom: Bottom?

    var isEmpty: Bool { !top && bottom == nil }

    /// - Parameters:
    ///   - phase: the phase the overlay first shows in.
    ///   - modelSupportsLivePreview: whether the selected model can
    ///     produce partials (the bubble needs both this and the pref).
    init(
        showPill: Bool,
        position: PillPosition,
        showLivePreview: Bool,
        phase: OverlayPhase,
        modelSupportsLivePreview: Bool
    ) {
        self.showPill = showPill
        self.position = position
        self.showLivePreview = showLivePreview
        let bubble = showLivePreview && modelSupportsLivePreview

        switch (showPill, position) {
        case (true, .top):
            top = true
            bottom = bubble ? Bottom(pill: .never, bubble: true) : nil
        case (true, .bottom):
            top = false
            bottom = Bottom(pill: .always, bubble: bubble)
        case (false, _) where showLivePreview:
            // Even when the model can't preview, keep the stand-in pill
            // so the user still sees that recording is on.
            top = false
            bottom = Bottom(pill: .standIn, bubble: bubble)
        case (false, _):
            if phase.isError {
                top = position == .top
                bottom = position == .bottom ? Bottom(pill: .always, bubble: false) : nil
            } else {
                top = false
                bottom = nil
            }
        }
    }
}

extension OverlayPhase {
    var isError: Bool {
        switch self {
        case .errorNoMic, .errorNoAccessibility, .errorNoModel, .errorGeneric: return true
        case .recording, .transcribing, .done: return false
        }
    }
}
