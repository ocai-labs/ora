//
//  NemotronStreamingTranscriber.swift
//  ora
//
//  `Transcriber` backed by NVIDIA's Nemotron 3.5 ASR Streaming 0.6B
//  (`nvidia/nemotron-3.5-asr-streaming-0.6b`, ~40 locales incl. Mandarin,
//  Japanese and Korean) via FluidAudio's
//  `StreamingNemotronMultilingualAsrManager`.
//
//  ## Why this model, next to Nemotron Unified
//
//  Nemotron Unified only covers 25 European languages. This one adds the
//  Asian languages (zh-CN, zh-TW, ja, ko, vi, hi, …) with the same
//  0.6B FastConformer-RNNT on the ANE, built-in punctuation, and the
//  language as an encoder input (`prompt_id`) so it can be pinned.
//  We ship the full-vocabulary `multilingual` build at the 1120 ms
//  chunk tier (FluidAudio: smaller chunks thin out punctuation, and
//  1120 ms is within 0.03 pp of 2240 ms on FLEURS) with the
//  `encoder_v2` encoder, which also compiles for M2/M3 Neural Engines.
//
//  ## Used as a batch model
//
//  The manager is a streaming session (reset → process → finish), but
//  Ora's contract is one-shot (`LivePreviewEngine` re-transcribes the
//  whole buffer each round, and the final pass does the same), so each
//  `transcribe` runs a complete fresh session. At FluidAudio's measured
//  ~66× real time that's ~0.15 s for 10 s of audio.
//
//  Unlike Nemotron Unified, the language is a per-session setting, not
//  baked into the loaded encoder, so changing it needs no reload.
//
//  ## Serialised sessions
//
//  The manager is an actor, but a session spans several awaits, and the
//  coordinator's final pass can start while a cancelled preview round is
//  still inside one. Interleaving two sessions on one manager would mix
//  their audio, so calls are chained: each waits for the previous one.
//

import AVFoundation
@preconcurrency import FluidAudio

@MainActor
final class NemotronStreamingTranscriber: Transcriber {
    static let modelId = "nemotron-streaming"

    /// Locales offered in the settings picker: NVIDIA's "transcription
    /// ready" and "broad coverage" sets (the "adaptation ready" ones need
    /// fine-tuning first, so we leave them out). Codes are the model's
    /// own prompt-dictionary keys (bare "ar": its "ar-AR" key would be
    /// named "Arabic (Argentina)" by Locale).
    static let languageCodes: [String] = [
        "zh-CN", "zh-TW", "ja-JP", "ko-KR", "vi-VN", "hi-IN",
        "en-US", "en-GB", "es-ES", "es-US", "fr-FR", "fr-CA", "de-DE",
        "it-IT", "pt-BR", "pt-PT", "nl-NL", "ru-RU", "uk-UA", "tr-TR",
        "ar", "pl-PL", "sv-SE", "cs-CZ", "nb-NO", "da-DK", "bg-BG",
        "fi-FI", "hr-HR", "sk-SK", "hu-HU", "ro-RO", "et-EE",
    ]

    private let downloader: FluidAudioDownloader
    private let preferences: Preferences
    private let loader = LazyLoader<StreamingNemotronMultilingualAsrManager>()

    /// Tail of the session chain — see "Serialised sessions".
    private var lastSession: Task<Void, Never>?

    init(downloader: FluidAudioDownloader, preferences: Preferences) {
        self.downloader = downloader
        self.preferences = preferences
    }

    // MARK: - Transcriber

    func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String {
        let samples = buffer.monoSamples()
        guard !samples.isEmpty else { throw TranscriberError.emptyAudio }

        let manager = try await ensureLoaded()
        try Task.checkCancellation()

        let language = preferences.nemotronStreamingLanguage
        let previous = lastSession
        let session = Task<String, Error> {
            await previous?.value
            try Task.checkCancellation()
            await manager.reset()
            await manager.setLanguage(language)
            _ = try await manager.process(samples: samples)
            return try await manager.finish()
        }
        lastSession = Task { _ = try? await session.value }

        do {
            let text = try await withTaskCancellationHandler {
                try await session.value
            } onCancel: {
                session.cancel()
            }
            return Self.tidyPunctuation(text)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw TranscriberError.inferenceFailed(error)
        }
    }

    // MARK: - Punctuation

    /// The model punctuates Chinese with ASCII marks (`三点, 我们`),
    /// leaves a space after `。` in Japanese, and usually ends without a
    /// terminal mark. For text containing Han or kana: ASCII `,?!:;` →
    /// full-width (`,` and `:` between digits, as in 1,000 or 10:30, are kept), and no
    /// space after a full-width mark. Then end every transcript with a
    /// terminal mark (`。` for Chinese/Japanese, `.` otherwise — Korean
    /// uses `.`). Applied to preview rounds and the final pass alike, so
    /// the last preview frame still matches the pasted text.
    nonisolated static func tidyPunctuation(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        let unspaced = text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF: true
            default: false
            }
        }
        if unspaced {
            let rules: [(String, String)] = [
                (#"(?<![0-9]),\s*|,(?![0-9])\s*"#, "，"),
                (#"\?\s*"#, "？"),
                (#"!\s*"#, "！"),
                (#"(?<![0-9]):\s*|:(?![0-9])\s*"#, "："),
                (#";\s*"#, "；"),
                (#"([。，？！：；、])\s+"#, "$1"),
            ]
            for (pattern, replacement) in rules {
                text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let terminals: Set<Character> = [".", "!", "?", "。", "！", "？", "…"]
        if let last = text.last, !terminals.contains(last) {
            if "，、：；,:;".contains(last) { text.removeLast() }
            text.append(unspaced ? "。" : ".")
        }
        return text
    }

    // MARK: - Lazy model load

    private func ensureLoaded() async throws -> StreamingNemotronMultilingualAsrManager {
        try await loader.get(
            isAvailable: { [downloader] in downloader.isInstalled(Self.modelId) },
            unavailableError: TranscriberError.modelNotDownloaded(name: "Nemotron Streaming"),
            load: {
                do {
                    let manager = StreamingNemotronMultilingualAsrManager()
                    try await manager.loadModels(from: FluidAudioDownloader.nemotronStreamingVariantDirectory)
                    return manager
                } catch {
                    throw TranscriberError.loadFailed(error)
                }
            }
        )
    }
}
