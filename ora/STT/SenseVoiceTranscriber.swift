//
//  SenseVoiceTranscriber.swift
//  ora
//
//  `Transcriber` backed by FunASR's SenseVoiceSmall via FluidAudio's
//  `SenseVoiceManager` (`FluidInference/sensevoice-small-coreml`).
//
//  ## Why this model
//
//  Chinese-first: FluidAudio measures 3.09 % CER on the full AISHELL-1
//  test set, and it also covers Cantonese, English, Japanese and Korean
//  with automatic language detection. It is non-autoregressive (one
//  encoder pass + greedy CTC, no decode loop), so a full re-transcription
//  of the buffer is cheap enough for the live preview's once-a-second
//  loop.
//
//  ## int8, with inverse text normalisation
//
//  The int8 encoder is ~240 MB (vs ~470 MB fp16) and FluidAudio reports
//  it accuracy-neutral; both run on the ANE. `textNorm` 14 is FunASR's
//  `withitn` query, which makes the model emit punctuation and digits —
//  FluidAudio defaults to 15 (`woitn`, bare text), which reads badly
//  as dictation.
//
//  ## Long recordings
//
//  The encoder's largest input bucket is ~108 s; FluidAudio truncates
//  anything longer. We transcribe longer buffers in ≤ 90 s pieces and
//  join them, so a long dictation loses nothing (a word cut at a piece
//  boundary may come out slightly off).
//

import AVFoundation
@preconcurrency import FluidAudio

@MainActor
final class SenseVoiceTranscriber: Transcriber {
    static let modelId = "sensevoice-small"

    /// FunASR's `withitn` text-norm query (punctuation + ITN on).
    nonisolated private static let textNormWithITN: Int32 = 14

    /// 90 s at 16 kHz — comfortably below the encoder's ~108 s bucket.
    nonisolated private static let maxPieceSamples = 90 * 16_000

    private let downloader: FluidAudioDownloader
    private let loader = LazyLoader<SenseVoiceManager>()

    init(downloader: FluidAudioDownloader) {
        self.downloader = downloader
    }

    // MARK: - Transcriber

    func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String {
        let samples = buffer.monoSamples()
        guard !samples.isEmpty else { throw TranscriberError.emptyAudio }

        let manager = try await ensureLoaded()
        try Task.checkCancellation()

        do {
            var pieces: [String] = []
            var start = 0
            while start < samples.count {
                try Task.checkCancellation()
                let end = min(start + Self.maxPieceSamples, samples.count)
                let text = try await manager.transcribe(audio: Array(samples[start..<end]))
                pieces.append(text)
                start = end
            }
            return Self.join(pieces)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscriberError.inferenceFailed(error)
        }
    }

    /// Joins per-piece transcripts: no separator next to Chinese or
    /// Japanese text (no word spaces), one space otherwise — Korean
    /// does space its words, so Hangul is joined like Latin text.
    nonisolated static func join(_ pieces: [String]) -> String {
        var result = ""
        for piece in pieces.map({ $0.trimmingCharacters(in: .whitespaces) }) where !piece.isEmpty {
            if let last = result.last, let first = piece.first,
               !(isUnspacedScript(last) || isUnspacedScript(first)) {
                result.append(" ")
            }
            result.append(piece)
        }
        return result
    }

    nonisolated private static func isUnspacedScript(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3000...0x303F,   // CJK punctuation
                 0x3040...0x30FF,   // kana
                 0x3400...0x4DBF,   // CJK ext. A
                 0x4E00...0x9FFF,   // CJK unified
                 0xFF00...0xFFEF:   // full-width forms
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Lazy model load

    private func ensureLoaded() async throws -> SenseVoiceManager {
        try await loader.get(
            isAvailable: { [downloader] in downloader.isInstalled(Self.modelId) },
            unavailableError: TranscriberError.modelNotDownloaded(name: "SenseVoice"),
            load: {
                do {
                    let directory = FluidAudioDownloader.senseVoiceCacheDirectory
                    let precision = FluidAudioDownloader.senseVoicePrecision
                    // `SenseVoiceModels.load` is synchronous CoreML
                    // loading — keep it off the main actor.
                    let models = try await Task.detached {
                        try SenseVoiceModels.load(from: directory, precision: precision)
                    }.value
                    return SenseVoiceManager(models: models, textNorm: Self.textNormWithITN)
                } catch {
                    throw TranscriberError.loadFailed(error)
                }
            }
        )
    }
}
