//
//  Transcriber.swift
//  ora
//
//  Protocol for "given a recorded audio buffer, return text". The
//  contract is intentionally tiny — one method, no streaming, no
//  partial results — because hold-to-talk dictation only ever needs
//  a final transcript at the moment the user releases the hotkey.
//
//  ## Why a protocol at all
//
//  Four backends implement this protocol: FluidAudioTranscriber
//  (Parakeet via ANE), WhisperKitTranscriber (Whisper via CoreML),
//  MLXTranscriber (Qwen3-ASR via GPU), and APITranscriber (cloud).
//  The coordinator picks the active backend at hotkey time based on
//  the user's selected model.
//
//  ## Threading
//
//  The whole target runs `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
//  which makes this protocol implicitly main-actor isolated. That's
//  the right level for the dictation pipeline: `Recorder.stop()`
//  returns on the main actor, the coordinator state machine lives on
//  the main actor, and the paste step is main-actor as well.
//  Implementations are free to hop to a background actor internally
//  (and `FluidAudioTranscriber` does, since `AsrManager` is its own
//  actor) — they just need to come back to main before returning.
//

import AVFoundation

protocol Transcriber {
    /// Transcribes a single 16 kHz mono Float32 PCM buffer into text.
    /// The buffer is consumed in one shot — there is no chunking or
    /// streaming contract. Implementations may load the underlying
    /// model lazily on the first call.
    ///
    /// Throws an implementation-specific error if the model isn't
    /// available, the audio is empty, or inference fails. Callers
    /// should treat any thrown error as fatal for the current
    /// utterance and surface a message to the user.
    func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String

    /// Loads the model and pays the heavy *first-inference* cost ahead
    /// of time, off the user's first hotkey press. See the default
    /// implementation for why this runs a real inference, not just a
    /// load. Best-effort and idempotent; safe to call repeatedly.
    func prewarm() async
}

extension Transcriber {
    /// Default prewarm: run one throwaway inference over ~1.2 s of
    /// silence. This matters because the expensive part of "first use"
    /// is the first *inference*, not the model load — measured in
    /// `spikes/retranscribe-speed-spike`, a WhisperKit pipeline loads in
    /// ~2.5 s but its first CoreML specialization runs tens of seconds to
    /// a couple of minutes; MLX/Qwen JITs its Metal kernels (~5 s) on the
    /// first `generate`; Parakeet specializes its ANE encoder on first
    /// run. Loading the model alone (the old WhisperKit-only `prewarm`)
    /// left all of that on the next dictation. Running a silent inference
    /// here pays it inside Settings/idle time instead.
    ///
    /// Best-effort: a not-downloaded model or any failure is swallowed —
    /// the real dictation path surfaces errors. Silence (not real audio)
    /// is the same warm-up signal `LivePreviewEngine` uses; 1.2 s clears
    /// FluidAudio's ≥1 s minimum. Cloud backends override to a no-op.
    func prewarm() async {
        let count = Int(1.2 * Recorder.targetSampleRate)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Recorder.targetSampleRate,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(count)
        ) else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        // AVAudioPCMBuffer memory isn't guaranteed zeroed — make it
        // explicit silence so the warm-up can't transcribe leftover heap.
        if let channel = buffer.floatChannelData?[0] {
            channel.update(repeating: 0, count: count)
        }
        _ = try? await transcribe(buffer)
    }
}
