//
//  NemotronUnifiedTranscriber.swift
//  ora
//
//  `Transcriber` backed by NVIDIA's Nemotron Unified ASR 0.6B
//  (`nvidia/nemotron-labs-unified-asr-0.6b`, 25 European languages) via
//  FluidAudio's `UnifiedAsrManager` — the offline/batch path: 15 s
//  full-attention windows with 2 s overlap, fp16 encoder.
//
//  ## Why this model, next to Parakeet v3
//
//  Parakeet TDT v3 has no language input: it auto-detects per utterance,
//  and FluidAudio's `language:` hint for it only filters by *script*
//  (French and English are both Latin), so a French speaker still gets
//  English words. Nemotron Unified takes the language as an encoder
//  input (`prompt_id`), so "French" really means French. It also
//  punctuates and capitalises, and it's the same size class as Parakeet
//  (0.6B FastConformer-RNNT on the ANE), fast enough for the live
//  preview's once-a-second re-transcription.
//
//  ## Language = reload
//
//  The prompt id is fixed when the manager loads its models
//  (`UnifiedConfig.family`), so a language change needs a fresh
//  manager. We keep one LazyLoader per language and swap it when
//  `Preferences.nemotronUnifiedLanguage` changes; the coordinator
//  re-warms on that change, so the reload normally happens in the
//  background rather than on the next dictation. A load that finishes
//  after the language moved on again is discarded unused (see
//  `ensureLoaded`); a stale load already in flight
//  still runs to completion — CoreML loads can't be interrupted — so
//  rapid switching can briefly have two loads going at once.
//
//  ## fp16, not int8
//
//  FluidAudio defaults to the int8 encoder (half the download). Its own
//  small French check came out worse for int8 (8.6 % vs 6.9 % WER), and
//  French accuracy is the reason this model is here, so we ship fp16
//  (~1.2 GB).
//

import AVFoundation
@preconcurrency import FluidAudio

@MainActor
final class NemotronUnifiedTranscriber: Transcriber {
    static let modelId = "nemotron-unified"

    private let downloader: FluidAudioDownloader
    private let preferences: Preferences

    private var loader = LazyLoader<UnifiedAsrManager>()
    private var loaderLanguage: NemotronUnifiedLanguage

    init(downloader: FluidAudioDownloader, preferences: Preferences) {
        self.downloader = downloader
        self.preferences = preferences
        self.loaderLanguage = Self.language(from: preferences.nemotronUnifiedLanguage)
    }

    /// ISO 639-1 codes of the languages the model can be pinned to
    /// (everything except "auto"), for the settings picker — so the UI
    /// doesn't import FluidAudio.
    static let languageCodes: [String] = NemotronUnifiedLanguage.allCases
        .filter { $0 != .auto }
        .map(\.rawValue)

    /// Unknown / stale stored codes fall back to auto-detect rather than
    /// failing the dictation.
    static func language(from code: String) -> NemotronUnifiedLanguage {
        NemotronUnifiedLanguage(rawValue: code) ?? .auto
    }

    // MARK: - Transcriber

    func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String {
        // [Float] is Sendable, AVAudioPCMBuffer is not — copy out on main
        // before crossing into the manager actor. Recorder already hands
        // us 16 kHz mono Float32.
        let samples = buffer.monoSamples()
        guard !samples.isEmpty else { throw TranscriberError.emptyAudio }

        let manager = try await ensureLoaded()
        // Same reasoning as FluidAudioTranscriber: a dictation cancelled
        // while waiting for the (shared, uninterruptible) load must not
        // also pay for an inference whose result is thrown away.
        try Task.checkCancellation()

        do {
            return try await manager.transcribe(samples)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscriberError.inferenceFailed(error)
        }
    }

    // MARK: - Lazy model load

    /// Returns a manager loaded for the CURRENT language. If the language
    /// changes while a load is in flight, the finished manager is stale:
    /// drop it (no inference on it — it's released as soon as the
    /// shared load task lets go) and wait for the current language's
    /// load instead. That load is the same shared `LazyLoader` task the
    /// language-change prewarm already started, so this never starts an
    /// extra load. Looping rather than throwing matters for the final
    /// pass: a throw here would discard the user's dictation.
    private func ensureLoaded() async throws -> UnifiedAsrManager {
        while true {
            let language = Self.language(from: preferences.nemotronUnifiedLanguage)
            if language != loaderLanguage {
                loader = LazyLoader()
                loaderLanguage = language
            }
            let directory = FluidAudioDownloader.nemotronUnifiedCacheDirectory
            let manager = try await loader.get(
                isAvailable: { [downloader] in downloader.isInstalled(Self.modelId) },
                unavailableError: TranscriberError.modelNotDownloaded(name: "Nemotron Unified"),
                load: {
                    do {
                        let manager = UnifiedAsrManager(
                            config: UnifiedConfig(family: .nemotronMultilingual(language)),
                            encoderPrecision: FluidAudioDownloader.nemotronUnifiedPrecision
                        )
                        try await manager.loadModels(from: directory)
                        return manager
                    } catch {
                        throw TranscriberError.loadFailed(error)
                    }
                }
            )
            if language == Self.language(from: preferences.nemotronUnifiedLanguage) {
                return manager
            }
            try Task.checkCancellation()
        }
    }
}
