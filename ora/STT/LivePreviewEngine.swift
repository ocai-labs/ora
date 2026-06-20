//
//  LivePreviewEngine.swift
//  ora
//
//  Drives the live transcript shown in the panel-style recording
//  overlay. The design is *periodic full-buffer re-transcription*
//  (spec docs/2026-06-10-streaming-live-preview-spec.md §5.0/§5.3):
//  every cadence (~1 s) the loop snapshots all audio accumulated so
//  far, runs it through the ordinary one-shot `Transcriber`, and
//  delivers the complete text — the overlay replaces the previous
//  partial wholesale, so the recognizer "revising earlier words" is
//  handled for free by whole-text replacement.
//
//  ## Why no SDK streaming API
//
//  The Phase 0 spike (spec §5.0) compared FluidAudio's streaming
//  managers against this re-transcription loop: the sliding-window
//  manager had 13 s first-word latency at default config and produced
//  broken word boundaries / duplicated segments at tuned configs, and
//  the true-streaming manager requires downloading separate
//  EOU/Nemotron models that TDT doesn't support. Re-transcribing the
//  full buffer with the existing `transcribe()` measured 0.13 s to
//  first word, needs zero new SDK surface or model downloads, and —
//  crucially — makes the final commit (one last full-buffer pass on
//  release) byte-for-byte identical to the last preview frame.
//
//  ## Pacing and lifetime
//
//  Each round starts one cadence AFTER the previous round *completes*,
//  never on a fixed timer — when inference takes longer than the
//  cadence the loop naturally slows down instead of piling rounds onto
//  AsrManager's serial queue (spec §5.3 "adaptive cadence"). Rounds
//  are skipped while the buffer is shorter than ~1.2 s (FluidAudio
//  hard-rejects < 1 s) — polled FAST (150 ms) so the first round fires
//  as soon as the gate is crossed — or unchanged since the previous
//  round (cadence-paced). A warm-up inference over silence runs while
//  the gate is still filling, so the model load and first-inference
//  overhead are paid inside the wait instead of on round 1. Past
//  ~120 s of audio the loop stops scheduling new rounds entirely
//  (O(n²) total compute cap, spec §5.3) and the last partial stays on
//  screen.
//
//  The loop is strictly best-effort: an inference error or
//  cancellation ends it silently, and `stop()` — called by the
//  coordinator on release, ESC/cancel, and error — just cancels the
//  task. The final dictation path through `stopRecordingAndTranscribe`
//  never depends on this engine in any way (spec §5.3: the two are
//  independent; preview failures must not affect the real transcribe).
//
//  ## Threading
//
//  Main-actor, like the rest of the pipeline (the target builds with
//  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`). The loop task runs on
//  the main actor; `transcribe` hops to the backend's own actor for
//  inference (see Transcriber.swift's threading note), so the main
//  thread is never blocked for the duration of a round. The per-round
//  buffer copies (snapshot memcpy, AVAudioPCMBuffer fill, monoSamples)
//  DO run on the main actor — a deliberate deviation from spec §5.2's
//  "off the main thread": at the 120 s cap that's a few copies of
//  ~7.7 MB once per second, single-digit milliseconds on Apple
//  silicon, not worth an actor hop for v1. Revisit in Phase 2 if
//  profiling disagrees.
//

import AVFoundation
import Foundation

@MainActor
final class LivePreviewEngine {
    /// Skip rounds below 1.2 s of audio (16 kHz). FluidAudio's
    /// AsrManager hard-rejects anything under 1 s ("Invalid audio
    /// data... Must be at least 1 second"), and the tap starts slightly
    /// after the engine does, so a 0.2 s margin keeps round 1 from
    /// racing the requirement on the first poll.
    nonisolated private static let minSampleCount = 19_200

    /// A failed round is retried on the next cadence; only this many
    /// consecutive failures end the loop. Transient conditions (audio
    /// still too short, a hiccuping first inference) must not kill the
    /// preview for the rest of the dictation.
    nonisolated private static let maxConsecutiveFailures = 3

    /// Poll interval while the buffer is still below the audio gate.
    /// First-word latency should be set by crossing the gate (~1.2 s),
    /// not by cadence quantization — sleeping a full cadence here let
    /// the gate crossing slip by and added up to ~1 s on top.
    nonisolated private static let preGatePoll: Duration = .milliseconds(150)

    /// Stop scheduling new rounds past ~120 s of audio — the O(n²)
    /// total-compute cap for long toggle-mode recordings (spec §5.3).
    nonisolated private static let maxSampleCount = Int(120 * Recorder.targetSampleRate)

    private let transcriber: any Transcriber
    private let cadence: Duration

    /// 16 kHz mono Float32 — the same layout `Recorder` accumulates
    /// and every `Transcriber` expects.
    private let format: AVAudioFormat

    /// The preview loop, or nil when stopped / never started.
    private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - transcriber: the *same instance* the final transcription
    ///     will use — sharing it means the LazyLoader loads the model
    ///     once and the backend's actor serializes preview rounds
    ///     against the final pass.
    ///   - cadence: pause between the end of one round and the start
    ///     of the next.
    init(transcriber: any Transcriber, cadence: Duration = .seconds(1)) {
        self.transcriber = transcriber
        self.cadence = cadence
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Recorder.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            // Same rationale as Recorder.init(): standard PCM formats
            // never fail to construct on Apple platforms.
            fatalError("Failed to construct preview AVAudioFormat (16 kHz mono Float32).")
        }
        self.format = format
    }

    /// Starts the preview loop. `snapshot` is polled once per round
    /// (typically `Recorder.snapshotSamples`); `onPartial` receives the
    /// full transcript-so-far after every successful round, on the main
    /// actor. Calling `start` on a running engine restarts it.
    func start(snapshot: @escaping () -> [Float], onPartial: @escaping (String) -> Void) {
        stop()
        // Capture dependencies by value — no `self` in the loop, so a
        // dropped engine can't be kept alive by its own task.
        let transcriber = self.transcriber
        let cadence = self.cadence
        let format = self.format
        task = Task {
            // Warm-up: load the model and run one inference over
            // silence while the audio gate (~1.2 s) is still filling.
            // On a cold backend this hides the model load (~0.3 s) and
            // the first-inference overhead (~0.45 s vs ~0.15 s warm)
            // inside time the loop would spend waiting anyway, so the
            // first *real* round returns in warm-round time. The
            // output is discarded; a failure here is not counted —
            // the normal loop's own failure accounting decides what's
            // fatal.
            if let warmup = Self.makeBuffer(
                samples: [Float](repeating: 0, count: Self.minSampleCount), format: format)
            {
                let warmupStart = Date()
                _ = try? await transcriber.transcribe(warmup)
                NSLog("[LivePreview] warm-up round done in %.2fs", Date().timeIntervalSince(warmupStart))
            }

            var previousCount = 0
            var round = 0
            var consecutiveFailures = 0
            while !Task.isCancelled {
                let samples = snapshot()

                // Long-recording cap: stop scheduling rounds for good;
                // the overlay keeps showing the last delivered partial.
                if samples.count > Self.maxSampleCount {
                    NSLog("[LivePreview] 120 s cap reached, freezing preview")
                    return
                }

                // Below the audio gate: poll fast so the first round
                // starts as soon as the gate is crossed, not at the
                // next cadence tick.
                if samples.count < Self.minSampleCount {
                    guard (try? await Task.sleep(for: Self.preGatePoll)) != nil else { return }
                    continue
                }

                // No new audio since the previous round — sleep a
                // cadence and re-poll rather than burning an inference
                // round on an identical buffer.
                if samples.count == previousCount {
                    guard (try? await Task.sleep(for: cadence)) != nil else { return }
                    continue
                }
                previousCount = samples.count
                round += 1

                guard let buffer = Self.makeBuffer(samples: samples, format: format) else { return }
                let roundStart = Date()
                do {
                    let text = try await transcriber.transcribe(buffer)
                    let elapsed = Date().timeIntervalSince(roundStart)
                    if Task.isCancelled {
                        NSLog("[LivePreview] round %d done in %.2fs but cancelled — discarded", round, elapsed)
                        return
                    }
                    NSLog(
                        "[LivePreview] round %d: %.1fs audio → %d chars in %.2fs",
                        round, Double(samples.count) / Recorder.targetSampleRate, text.count, elapsed)
                    consecutiveFailures = 0
                    if !text.isEmpty { onPartial(text) }
                } catch {
                    // Cancellation is the normal stop path — exit
                    // silently. Other failures are retried next cadence
                    // (the buffer keeps growing, so e.g. "audio too
                    // short" heals by itself); only a persistent streak
                    // ends the loop. Either way a failed round must
                    // never disturb the real dictation pipeline
                    // (spec §5.3).
                    if error is CancellationError { return }
                    consecutiveFailures += 1
                    NSLog(
                        "[LivePreview] round %d failed (%d/%d): %@",
                        round, consecutiveFailures, Self.maxConsecutiveFailures,
                        Self.shortDescription(of: error))
                    if consecutiveFailures >= Self.maxConsecutiveFailures {
                        NSLog("[LivePreview] stopping preview after %d consecutive failures", consecutiveFailures)
                        return
                    }
                    // Let the next attempt re-run even if the sample
                    // count hasn't grown (e.g. release already stopped
                    // the tap but a retry can still succeed).
                    previousCount = 0
                }

                // Adaptive pacing: the next round starts one cadence
                // after this one *completed*, so a slow inference pass
                // lowers the loop frequency instead of piling up.
                guard (try? await Task.sleep(for: cadence)) != nil else { return }
            }
        }
    }

    /// Cancels the preview loop. Safe to call repeatedly, before the
    /// first round has run, or when `start` was never called. An
    /// in-flight inference pass finishes on the backend's actor (it
    /// can't be interrupted mid-kernel) but its result is discarded.
    func stop() {
        task?.cancel()
        task = nil
    }

    // MARK: - Buffer assembly

    /// Wraps a snapshot in a PCM buffer for `transcribe`. Same shape as
    /// `Recorder.makeBuffer` but tolerant: a preview round is optional
    /// work, so an allocation failure ends the loop instead of trapping.
    nonisolated private static func makeBuffer(samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                channel.update(from: src.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }

    /// One-line error description for the Console breadcrumb — the
    /// preview loop logs at most once per dictation, on its way out.
    nonisolated private static func shortDescription(of error: Error) -> String {
        String(error.localizedDescription.prefix(120))
    }
}
