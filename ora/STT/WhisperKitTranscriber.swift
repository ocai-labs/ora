//
//  WhisperKitTranscriber.swift
//  ora
//
//  Concrete `Transcriber` backed by OpenAI Whisper via WhisperKit.
//  This and `WhisperKitModelDownloader` are the only files that import
//  WhisperKit — keeping the SDK isolated to these two adapters means
//  the rest of the app talks to plain Swift types.
//
//  ## Lazy model loading
//
//  Loading the WhisperKit pipeline (mel spectrogram, encoder, decoder)
//  is expensive on first launch. We load lazily on the first
//  `transcribe(_:)` call rather than at app launch so that:
//
//   1. Cold-launch latency is paid by the first dictation, not by the
//      menu bar appearing.
//   2. We don't have to handle "model isn't downloaded yet" at app
//      startup.
//
//  Concurrent calls to `transcribe(_:)` while the pipeline is still
//  loading share a single `Task` via `loadTask`, so we never start the
//  load twice. Once loaded, `pipe` is reused for the process lifetime.
//
//  ## Sample extraction
//
//  We pull `[Float]` out of the `AVAudioPCMBuffer` on the main actor,
//  then pass to WhisperKit's `transcribe(audioArray:)`. Recorder
//  guarantees the buffer is 16 kHz mono Float32, which is what Whisper
//  expects.
//

import AVFoundation
import WhisperKit

@MainActor
final class WhisperKitTranscriber: Transcriber {
    private let modelId: String
    private let downloader: WhisperKitModelDownloader

    private let loader = LazyLoader<WhisperKit>()

    init(modelId: String, downloader: WhisperKitModelDownloader) {
        self.modelId = modelId
        self.downloader = downloader
    }

    // MARK: - Transcriber

    func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String {
        let samples = buffer.monoSamples()
        guard !samples.isEmpty else { throw TranscriberError.emptyAudio }

        let pipe = try await ensureLoaded()

        // Bail before inference if the dictation was cancelled while
        // waiting for the (uninterruptible, shared) model load — the
        // result would be discarded anyway.
        try Task.checkCancellation()

        do {
            // transcribe(audioArray:) returns one TranscriptionResult
            // per chunk. Default options produce a single element, but
            // join all of them so a future chunkingStrategy change
            // can't silently truncate long dictations to chunk one.
            let results = try await pipe.transcribe(audioArray: samples)
            return Self.joinedTranscript(results.map(\.text))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscriberError.inferenceFailed(error)
        }
    }

    /// Joins per-chunk transcription texts into one transcript. Pure —
    /// extracted so the multi-chunk behavior is unit-testable without
    /// constructing WhisperKit result types.
    static func joinedTranscript(_ chunks: [String]) -> String {
        chunks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // NOTE: prewarm() is the protocol default (Transcriber.swift) — it
    // runs a silent inference, not just ensureLoaded(), because CoreML
    // specialization happens on the first *prediction*, not on pipeline
    // load (measured in spikes/retranscribe-speed-spike: load ~2.5 s,
    // first inference up to ~130 s). The old load-only override left
    // that cost on the first dictation; the default pays it during the
    // prewarm. Subsequent launches hit Apple's on-disk specialization
    // cache regardless.

    // MARK: - Lazy model load

    private func ensureLoaded() async throws -> WhisperKit {
        try await loader.get(
            isAvailable: { [downloader, modelId] in downloader.isInstalled(modelId) },
            unavailableError: TranscriberError.modelNotDownloaded(name: "Whisper"),
            load: { [downloader, modelId] in
                guard let entry = WhisperKitModelConfig.models[modelId] else {
                    throw TranscriberError.modelNotDownloaded(name: "Whisper")
                }
                let folder = downloader.cacheDirectory(modelId)?.path
                do {
                    let config = WhisperKitConfig(
                        model: entry.variant,
                        modelFolder: folder,
                        verbose: false,
                        download: false
                    )
                    return try await WhisperKit(config)
                } catch {
                    throw TranscriberError.loadFailed(error)
                }
            }
        )
    }
}
