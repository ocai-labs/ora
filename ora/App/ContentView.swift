//
//  ContentView.swift
//  ora
//
//  Created by Kristamps Wang on 4/8/26.
//

import SwiftUI

struct ContentView: View {
    @State private var selection: SettingsPage = .general

    var body: some View {
        NavigationSplitView {
            SettingsNavigationBar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 200)
        } detail: {
            detailView(for: selection)
                .frame(minWidth: 440)
                .padding(.top, -12)
                .navigationTitle(selection.title)
        }
        .frame(minWidth: 680, maxWidth: 680, minHeight: 460)
        .onAppear(perform: drainPendingPage)
        .onChange(of: SettingsNavigator.shared.pendingPage) { _, _ in
            drainPendingPage()
        }
    }

    /// Reads any pending page hint from the navigator, applies it,
    /// and clears it so a subsequent open doesn't re-jump.
    private func drainPendingPage() {
        if let page = SettingsNavigator.shared.pendingPage {
            selection = page
            SettingsNavigator.shared.pendingPage = nil
        }
    }

    @ViewBuilder
    private func detailView(for page: SettingsPage) -> some View {
        switch page {
        case .general:
            GeneralPage()
        case .dictation:
            DictationPage()
        case .models:
            ModelsPage()
        }
    }
}

#Preview {
    ContentView()
}
