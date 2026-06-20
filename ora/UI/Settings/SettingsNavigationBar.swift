//
//  SettingsNavigationBar.swift
//  ora
//
//  Reusable vertical list of settings pages.
//  Designed to work both as a sidebar inside NavigationSplitView
//  and as the content of a menu bar dropdown popover.
//

import SwiftUI

struct SettingsNavigationBar: View {
    @Binding var selection: SettingsPage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPage.allCases) { page in
                row(for: page)
            }
        }
        .padding(8)
        .frame(minWidth: 180, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(for page: SettingsPage) -> some View {
        Button {
            selection = page
        } label: {
            HStack(spacing: 10) {
                Image(systemName: page.icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                Text(page.title)
                    .font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selection == page ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            .foregroundStyle(selection == page ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

#Preview("Sidebar") {
    StatefulPreview()
        .frame(width: 220, height: 300)
}

private struct StatefulPreview: View {
    @State private var selection: SettingsPage = .general
    var body: some View {
        SettingsNavigationBar(selection: $selection)
    }
}
