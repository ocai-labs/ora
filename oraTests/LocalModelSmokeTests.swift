//
//  LocalModelSmokeTests.swift
//  oraTests
//
//  Opt-in end-to-end check of the FluidAudio CJK models: downloads the
//  model if needed (through the app's own downloader + install check),
//  then transcribes real speech the way Ora does — a live-preview-style
//  series of growing prefixes, then one final full-buffer pass — and
//  writes the text and per-round latency to `<audio dir>/results.txt`.
//
//  Off by default (multi-hundred-MB downloads). Run with:
//
//    TEST_RUNNER_ORA_MODEL_TESTS=1 \
//    TEST_RUNNER_ORA_MODEL_TEST_AUDIO=/path/to/wavs \
//    xcodebuild test -scheme ora -only-testing:oraTests/LocalModelSmokeTests
//
//  The audio directory holds `<lang>.wav` files (16 kHz mono), e.g.
//  generated with `say -v Tingting -o zh.wav --data-format=LEF32@16000`.
//

import AVFoundation
import Foundation
import Testing
@testable import ora

@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ORA_MODEL_TESTS"] == "1"), .serialized)
struct LocalModelSmokeTests {
    private var audioDirectory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORA_MODEL_TEST_AUDIO"] ?? ".")
    }

    private static let languages = ["zh", "yue", "ko", "ja", "en"]

    @Test("Parakeet Ultra transcribes English and European speech")
    func parakeetUltra() async throws {
        let downloader = FluidAudioDownloader()
        try await ensureDownloaded(FluidAudioTranscriber.modelId, downloader)
        let transcriber = FluidAudioTranscriber(downloader: downloader)
        for lang in ["en", "fr", "de"] {
            try await run(transcriber, label: "Parakeet Ultra", lang: lang)
        }
    }

    @Test("Nemotron Unified transcribes European speech with the language pinned")
    func nemotronUnified() async throws {
        let downloader = FluidAudioDownloader()
        try await ensureDownloaded(NemotronUnifiedTranscriber.modelId, downloader)
        let suite = "ora.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let transcriber = NemotronUnifiedTranscriber(downloader: downloader, preferences: preferences)
        for lang in ["en", "fr", "de"] {
            preferences.nemotronUnifiedLanguage = lang
            try await run(transcriber, label: "Nemotron Unified \(lang)", lang: lang)
        }
    }

    @Test("SenseVoice Small transcribes CJK speech fast enough for live preview")
    func senseVoice() async throws {
        let downloader = FluidAudioDownloader()
        try await ensureDownloaded(SenseVoiceTranscriber.modelId, downloader)
        let transcriber = SenseVoiceTranscriber(downloader: downloader)
        for lang in Self.languages {
            try await run(transcriber, label: "SenseVoice", lang: lang)
        }
    }

    /// Regression for the 30 s SenseVoice limit: the preprocessor only
    /// takes 0.2–30 s, and > 30 s dictations used to throw (and were
    /// then dropped silently). Needs no audio files — a 45 s synthetic
    /// buffer must transcribe without throwing — but if `<lang>.wav`
    /// exists it is tiled past 45 s and must yield text.
    @Test("SenseVoice transcribes recordings longer than 30 s")
    func senseVoiceLongAudio() async throws {
        let downloader = FluidAudioDownloader()
        try await ensureDownloaded(SenseVoiceTranscriber.modelId, downloader)
        let transcriber = SenseVoiceTranscriber(downloader: downloader)

        // Faint noise rather than digital silence, so the encoder sees
        // a realistic floor.
        var generator = SystemRandomNumberGenerator()
        let noise = (0..<(45 * 16_000)).map { _ in Float.random(in: -0.002...0.002, using: &generator) }
        let t = Date()
        let noiseText = try await transcriber.transcribe(makeBuffer(noise))
        log("[smoke] SenseVoice long noise 45.0 s in \(String(format: "%.3f", Date().timeIntervalSince(t))) s → \"\(noiseText)\"")

        for lang in ["zh", "en"] {
            let url = audioDirectory.appendingPathComponent("\(lang).wav")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let clip = try loadSamples(url)
            guard !clip.isEmpty else { continue }
            var long: [Float] = []
            while long.count < 45 * 16_000 { long += clip }
            let start = Date()
            let text = try await transcriber.transcribe(makeBuffer(long))
            #expect(!text.isEmpty)
            log("""
                [smoke] SenseVoice long [\(lang)] audio=\(String(format: "%.1f", Double(long.count) / 16_000)) s \
                final=\(String(format: "%.3f", Date().timeIntervalSince(start))) s
                [smoke]   final: \(text)
                """)
        }
    }

    @Test("Nemotron 3.5 Streaming transcribes CJK speech, auto and pinned")
    func nemotronStreaming() async throws {
        let downloader = FluidAudioDownloader()
        try await ensureDownloaded(NemotronStreamingTranscriber.modelId, downloader)
        let suite = "ora.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let transcriber = NemotronStreamingTranscriber(downloader: downloader, preferences: preferences)

        let pinned = ["zh": "zh-CN", "ko": "ko-KR", "ja": "ja-JP", "en": "en-US"]
        for lang in ["zh", "ko", "ja", "en"] {
            preferences.nemotronStreamingLanguage = "auto"
            try await run(transcriber, label: "Nemotron auto", lang: lang)
            preferences.nemotronStreamingLanguage = pinned[lang]!
            try await run(transcriber, label: "Nemotron \(pinned[lang]!)", lang: lang)
        }
    }

    // MARK: - Helpers

    private func ensureDownloaded(_ id: String, _ downloader: FluidAudioDownloader) async throws {
        if downloader.isInstalled(id) { return }
        let start = Date()
        try await downloader.download(id) { _ in }
        #expect(downloader.isInstalled(id))
        log("[smoke] downloaded \(id) in \(String(format: "%.0f", Date().timeIntervalSince(start))) s")
    }

    private func run(_ transcriber: any Transcriber, label: String, lang: String) async throws {
        let url = audioDirectory.appendingPathComponent("\(lang).wav")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let samples = try loadSamples(url)

        // First call includes model load + first-inference specialization.
        let warm = Date()
        await transcriber.prewarm()
        let warmSeconds = Date().timeIntervalSince(warm)

        // Live-preview rounds: prefixes growing by 1 s from 1.2 s.
        var roundTimes: [Double] = []
        var lastPartial = ""
        var length = 19_200
        while length < samples.count {
            let t = Date()
            lastPartial = try await transcriber.transcribe(makeBuffer(Array(samples[0..<length])))
            roundTimes.append(Date().timeIntervalSince(t))
            length += 16_000
        }

        let t = Date()
        let final = try await transcriber.transcribe(makeBuffer(samples))
        let finalSeconds = Date().timeIntervalSince(t)

        #expect(!final.isEmpty)
        let maxRound = roundTimes.max() ?? 0
        let meanRound = roundTimes.isEmpty ? 0 : roundTimes.reduce(0, +) / Double(roundTimes.count)
        log("""
            [smoke] \(label) [\(lang)] audio=\(String(format: "%.1f", Double(samples.count) / 16_000)) s \
            prewarm=\(String(format: "%.2f", warmSeconds)) s rounds=\(roundTimes.count) \
            mean=\(String(format: "%.3f", meanRound)) s max=\(String(format: "%.3f", maxRound)) s \
            final=\(String(format: "%.3f", finalSeconds)) s
            [smoke]   last partial: \(lastPartial)
            [smoke]   final:        \(final)
            """)
    }

    /// Appends to `<audio dir>/results.txt`: the test host is the app,
    /// whose stdout doesn't reach xcodebuild's log.
    private func log(_ line: String) {
        let url = audioDirectory.appendingPathComponent("results.txt")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private func loadSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        #expect(format.sampleRate == 16_000 && format.channelCount == 1)
        return buffer.monoSamples()
    }

    private func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }
}
