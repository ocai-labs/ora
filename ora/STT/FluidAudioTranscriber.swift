//
//  FluidAudioTranscriber.swift
//  ora
//
//  Concrete `Transcriber` backed by FluidAudio's Parakeet TDT 0.6B v3
//  pipeline. This and `FluidAudioDownloader` are the only files in the
//  project that import FluidAudio — keeping the SDK isolated to the
//  Models/ and STT/ adapters means the rest of the app talks to plain
//  Swift types and doesn't need to learn FluidAudio's vocabulary.
//
//  ## Lazy model loading
//
//  Loading the four CoreML models (preprocessor, encoder, decoder,
//  joint) takes ~1–2 s on first launch on an M-series Mac and is
//  amortised across every subsequent transcription. We do it lazily
//  on the first `transcribe(_:)` call rather than at app launch so
//  that:
//
//   1. Cold-launch latency is paid by the first dictation, not by
//      the menu bar appearing — better for users who launch Ora and
//      then walk away.
//   2. We don't have to handle "model isn't downloaded yet" at app
//      startup. The first `transcribe` either finds the cache and
//      loads it, or throws `.modelNotDownloaded`.
//
//  Concurrent calls to `transcribe(_:)` while the model is still
//  loading share a single `Task` via `loadTask`, so we never start
//  the load twice. Once loaded, `manager` is reused for the lifetime
//  of the process.
//
//  ## Decoder state per call
//
//  TDT decoder state (`TdtDecoderState`) is meant to carry context
//  across chunks of a streaming transcription. Hold-to-talk gives us
//  one independent utterance per release, with no continuity from
//  the previous one, so we allocate a fresh state per `transcribe`
//  call. The cost is negligible (~150 KB of zeroed MLMultiArrays).
//
//  ## Sample extraction
//
//  We pull `[Float]` out of the `AVAudioPCMBuffer` on the main actor
//  before hopping to `AsrManager` (an actor). Passing the array
//  instead of the buffer sidesteps the AVFoundation Sendable warning
//  and matches AsrManager's `transcribe([Float], decoderState:)`
//  overload directly. Recorder already guarantees the buffer is
//  16 kHz mono Float32 (the format Parakeet wants), so no resample
//  is needed here.
//

import AVFoundation
@preconcurrency import FluidAudio

@MainActor
final class FluidAudioTranscriber: Transcriber {
    private let modelId: String
    private let downloader: FluidAudioDownloader

    private let loader = LazyLoader<AsrManager>()

    // No default value for `downloader`: evaluating a main-actor
    // isolated initializer as a default argument happens in a
    // nonisolated context and trips strict concurrency.
    init(modelId: String = "parakeet-v3", downloader: FluidAudioDownloader) {
        self.modelId = modelId
        self.downloader = downloader
    }

    // MARK: - Transcriber

    func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String {
        // Pull samples out on the main actor before crossing into the
        // AsrManager actor — `[Float]` is Sendable, AVAudioPCMBuffer is
        // not. Recorder hands us 16 kHz mono Float32 already, so this
        // is a single channel-pointer copy.
        let samples = buffer.monoSamples()
        guard !samples.isEmpty else { throw TranscriberError.emptyAudio }

        let manager = try await ensureLoaded()

        // The model load above is not interruptible (it's shared with
        // other callers), but a dictation cancelled while waiting for
        // it must not also pay for a full inference pass — the result
        // would be discarded, and AsrManager serializes, so it would
        // delay the user's *next* dictation too.
        try Task.checkCancellation()

        // Fresh decoder state per utterance — see file header. `make`
        // is the non-throwing variant; the underlying allocation only
        // fails on actual OOM, which `make` chooses to crash on rather
        // than thread an Error through every call site.
        var state = TdtDecoderState.make()

        do {
            let result = try await manager.transcribe(samples, decoderState: &state)
            return result.text
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscriberError.inferenceFailed(error)
        }
    }

    // MARK: - Lazy model load

    private func ensureLoaded() async throws -> AsrManager {
        try await loader.get(
            isAvailable: { [downloader, modelId] in downloader.isInstalled(modelId) },
            unavailableError: TranscriberError.modelNotDownloaded(name: "Parakeet"),
            load: { [modelId] in
                do {
                    let version: AsrModelVersion = modelId == "parakeet-v2" ? .v2 : .v3
                    let models = try await AsrModels.loadFromCache(version: version)
                    let manager = AsrManager(config: .default)
                    try await manager.loadModels(models)
                    return manager
                } catch {
                    throw TranscriberError.loadFailed(error)
                }
            }
        )
    }
}
