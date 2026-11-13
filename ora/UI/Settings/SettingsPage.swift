//
//  SettingsPage.swift
//  ora
//
//  Enum of pages shown in the settings navigation bar.
//

import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case interface
    case dictation
    case models
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .interface: "Interface"
        case .dictation: "Dictation"
        case .history: "History"
        case .models: "Models"
        }
    }

    var icon: String {
        switch self {
        case .general: "gear"
        case .interface: "sun.max"
        case .dictation: "mic"
        case .history: "clock.arrow.circlepath"
        case .models: "sparkle"
        }
    }
}
