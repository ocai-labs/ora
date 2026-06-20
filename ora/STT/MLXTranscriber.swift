//
//  MLXTranscriber.swift
//  ora
//
//  Concrete `Transcriber` backed by Qwen3-ASR via mlx-audio-swift.
//  This and `MLXModelDownloader` are the only files in the project
//  that import MLXAudioSTT — keeping the SDK isolated to the Models/
//  and STT/ adapters means the rest of the app talks to plain Swift
//  types and doesn't need to learn the MLX vocabulary.
//
//  ## Lazy model loading
//
//  Loading the Qwen3-ASR model is expensive on first launch. We load
//  it lazily on the first `transcribe(_:)` call rather than at app
//  launch so that:
//
//   1. Cold-launch latency is paid by the first dictation, not by
//      the menu bar appearing.
//   2. We don't have to handle "model isn't downloaded yet" at app
//      startup. The first `transcribe` either finds the cache and
//      loads it, or throws `.modelNotDownloaded`.
//
//  Concurrent calls to `transcribe(_:)` while the model is still
//  loading share a single `Task` via `loadTask`, so we never start
//  the load twice. Once loaded, `model` is reused for the lifetime
//  of the process.
//
//  ## Sample extraction
//
//  We pull `[Float]` out of the `AVAudioPCMBuffer` on the main actor,
//  then convert to `MLXArray` immediately before calling `generate`.
//  Recorder already guarantees the buffer is 16 kHz mono Float32 (the
//  format Qwen3-ASR wants), so no resampling is needed here.
//

import AVFoundation
import MLX
import MLXAudioSTT

@MainActor
final class MLXTranscriber: Transcriber {
    private let modelId: String
    private let downloader: MLXModelDownloader

    private let loader = LazyLoader<Qwen3ASRModel>()

    /// `Qwen3ASRModel.generate(audio:)` is a *synchronous* call in the
    /// linked mlx-audio-swift version — running it on the main actor
    /// would freeze the UI for the full inference (seconds for long
    /// dictations). One shared serial queue keeps inference off main
    /// AND serializes overlapping calls (a cancelled dictation's
    /// in-flight generate vs. the next dictation's) since the model
    /// object is not thread-safe.
    nonisolated private static let inferenceQueue = DispatchQueue(
        label: "com.ora.mlx-inference",
        qos: .userInitiated
    )

    init(modelId: String, downloader: MLXModelDownloader) {
        self.modelId = modelId
        self.downloader = downloader
    }

    // MARK: - Transcriber

    func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String {
        // Pull samples out on the main actor before crossing into the
        // model — `[Float]` is Sendable, AVAudioPCMBuffer is not.
        // Recorder hands us 16 kHz mono Float32 already, so this is
        // a single channel-pointer copy.
        let samples = buffer.monoSamples()
        guard !samples.isEmpty else { throw TranscriberError.emptyAudio }

        let loadedModel = try await ensureLoaded()

        // Bail before inference if the dictation was cancelled while
        // waiting for the (uninterruptible, shared) model load — the
        // result would be discarded, and the GPU work would delay the
        // user's next dictation.
        try Task.checkCancellation()

        // Hop to the inference queue (see its doc comment). The model
        // reference crosses isolation via nonisolated(unsafe); safety
        // comes from the serial queue — all generate() calls for the
        // process go through it, never concurrently.
        nonisolated(unsafe) let model = loadedModel
        let text: String = await withCheckedContinuation { cont in
            Self.inferenceQueue.async {
                let output = model.generate(audio: MLXArray(samples))
                cont.resume(returning: output.text)
            }
        }
        return text
    }

    // MARK: - Lazy model load

    private func ensureLoaded() async throws -> Qwen3ASRModel {
        try await loader.get(
            isAvailable: { [downloader, modelId] in downloader.isInstalled(modelId) },
            unavailableError: TranscriberError.modelNotDownloaded(name: "Qwen3-ASR"),
            load: { [modelId] in
                guard let entry = MLXModelConfig.models[modelId] else {
                    throw TranscriberError.modelNotDownloaded(name: "Qwen3-ASR")
                }
                do {
                    return try await Qwen3ASRModel.fromPretrained(entry.repoId)
                } catch {
                    throw TranscriberError.loadFailed(error)
                }
            }
        )
    }
}
