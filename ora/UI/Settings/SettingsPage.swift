//
//  SettingsPage.swift
//  ora
//
//  Enum of pages shown in the settings navigation bar.
//

import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case models
    case general
    case dictation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .dictation: "Dictation"
        case .models: "Models"
        }
    }

    var icon: String {
        switch self {
        case .general: "gear"
        case .dictation: "mic"
        case .models: "sparkle"
        }
    }
}
