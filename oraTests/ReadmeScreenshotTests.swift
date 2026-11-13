//
//  ReadmeScreenshotTests.swift
//  oraTests
//
//  Opt-in helper that renders the real Settings window on the Models
//  page (dark mode, Local filter) and writes it as a PNG, for
//  `assets/models.png` in the README. Drawn in-process, so it needs no
//  Screen Recording permission. Run with:
//
//    TEST_RUNNER_ORA_SCREENSHOT=/path/to/models.png \
//    xcodebuild test -scheme ora -only-testing:oraTests/ReadmeScreenshotTests
//

import AppKit
import SwiftUI
import Testing
@testable import ora

@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ORA_SCREENSHOT"] != nil))
struct ReadmeScreenshotTests {
    @Test("render the Models page for the README")
    func modelsPage() async throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORA_SCREENSHOT"]!)

        let suite = "ora.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.selectedModelId = FluidAudioTranscriber.modelId

        SettingsNavigator.shared.pendingPage = .models
        let root = ContentView()
            .environment(preferences)
            .environment(ModelManager.shared)
            .environment(DictationCoordinator.shared.inputDevices)
            .preferredColorScheme(.dark)

        let size = NSSize(width: 680, height: 470)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        let previousAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .darkAqua)
        defer { NSApp.appearance = previousAppearance }
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: root)
        window.setContentSize(size)
        window.center()
        // Key + active, so the traffic lights are coloured and the
        // sidebar selection uses the accent colour.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        // Let SwiftUI lay out, load brand icons and settle animations.
        try await Task.sleep(for: .seconds(2))

        guard let frameView = window.contentView?.superview else {
            Issue.record("no window frame view"); return
        }
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else {
            Issue.record("no bitmap rep"); return
        }
        frameView.cacheDisplay(in: bounds, to: rep)

        // The capture is the window's rectangle; clip it to the window's
        // rounded corners so it looks like the window on screen.
        let width = rep.pixelsWide, height = rep.pixelsHigh
        let scale = CGFloat(width) / bounds.width
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let radius = 16 * scale
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        context.draw(try #require(rep.cgImage), in: rect)
        let clipped = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        let png = try #require(clipped.representation(using: .png, properties: [:]))
        try png.write(to: output)
    }
}
