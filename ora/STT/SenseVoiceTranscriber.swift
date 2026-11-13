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
//  The hard limit is the CoreML *preprocessor*, not the encoder: its
//  waveform input is declared `RangeDims [3200, 480000]` samples, i.e.
//  0.2 s .. 30 s at 16 kHz, and anything outside that throws (the
//  encoder's ~108 s bucket never comes into play). Before this was
//  known, pieces were 90 s, so every dictation over 30 s failed — and
//  the live preview froze at the 30 s mark for the same reason.
//
//  `planPieces` keeps any buffer of ≤ 30 s whole and splits longer ones
//  into pieces of at most 25 s, cutting at the quietest 20 ms frame in
//  the 5 s before each nominal boundary so a cut lands in a pause
//  rather than mid-word where possible. Because each cut piece is
//  ≤ 25 s and only made while > 30 s remain, the final piece is always
//  > 5 s — no piece ever drops below the 0.2 s floor. A lone buffer
//  shorter than the floor is zero-padded up to it. Pieces are joined
//  with `join` (no space next to CJK text).
//

import AVFoundation
@preconcurrency import FluidAudio

@MainActor
final class SenseVoiceTranscriber: Transcriber {
    static let modelId = "sensevoice-small"

    /// FunASR's `withitn` text-norm query (punctuation + ITN on).
    nonisolated private static let textNormWithITN: Int32 = 14

    /// The preprocessor's waveform bounds (`RangeDims [3200, 480000]`):
    /// 0.2 s .. 30 s at 16 kHz. See "Long recordings".
    nonisolated static let minPieceSamples = 3_200
    nonisolated static let maxPieceSamples = 480_000

    /// Nominal piece length when a buffer must be split: 25 s, leaving
    /// 5 s of headroom under the 30 s limit for the final piece.
    nonisolated static let targetPieceSamples = 25 * 16_000

    /// How far before a nominal boundary to look for a pause: 5 s.
    nonisolated static let cutSearchSamples = 5 * 16_000

    /// Frame size for the pause search: 20 ms.
    nonisolated static let energyFrameSamples = 320

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

        let ranges = Self.planPieces(count: samples.count) { window in
            Self.quietestPoint(in: samples, within: window)
        }

        do {
            var pieces: [String] = []
            for range in ranges {
                try Task.checkCancellation()
                var piece = Array(samples[range])
                if piece.count < Self.minPieceSamples {
                    piece.append(contentsOf: repeatElement(0, count: Self.minPieceSamples - piece.count))
                }
                pieces.append(try await manager.transcribe(audio: piece))
            }
            return Self.join(pieces)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscriberError.inferenceFailed(error)
        }
    }

    // MARK: - Piece planning

    /// Splits `count` samples into contiguous, gap-free ranges the
    /// preprocessor accepts. Pure — see "Long recordings" for the rules.
    ///
    /// - A buffer of ≤ `maxLength` stays one piece (it may be shorter
    ///   than `minLength`; the caller pads that lone case).
    /// - Otherwise, while more than `maxLength` remains, a piece ending
    ///   at `cut(window)` is emitted, where `window` is the closed range
    ///   `[max(start + minLength, start + target − searchWindow),
    ///   start + target]`; the result is clamped into that window.
    ///   With `target + minLength ≤ maxLength`, the remainder is then
    ///   always > `maxLength − target` ≥ `minLength`.
    nonisolated static func planPieces(
        count: Int,
        target: Int = targetPieceSamples,
        maxLength: Int = maxPieceSamples,
        minLength: Int = minPieceSamples,
        searchWindow: Int = cutSearchSamples,
        cut: (ClosedRange<Int>) -> Int = { $0.upperBound }
    ) -> [Range<Int>] {
        precondition(minLength > 0 && target >= minLength && target + minLength <= maxLength,
                     "planPieces needs minLength ≤ target ≤ maxLength − minLength")
        guard count > 0 else { return [] }

        var ranges: [Range<Int>] = []
        var start = 0
        while count - start > maxLength {
            let upper = start + target
            let lower = max(start + minLength, upper - max(searchWindow, 0))
            let window = lower...upper
            let end = min(max(cut(window), lower), upper)
            ranges.append(start..<end)
            start = end
        }
        ranges.append(start..<count)
        return ranges
    }

    /// The middle of the lowest-energy `frame`-sample frame that fits
    /// inside `window` (and inside `samples`) — a likely pause to cut
    /// at. Ties go to the later frame, keeping pieces long. Falls back
    /// to `window.upperBound` when no full frame fits.
    nonisolated static func quietestPoint(
        in samples: [Float],
        within window: ClosedRange<Int>,
        frame: Int = energyFrameSamples
    ) -> Int {
        let lower = max(window.lowerBound, 0)
        let upper = min(window.upperBound, samples.count)
        guard frame > 0, upper - lower >= frame else { return window.upperBound }

        var bestStart = lower
        var bestEnergy = Float.infinity
        samples.withUnsafeBufferPointer { buffer in
            var frameStart = lower
            while frameStart + frame <= upper {
                var energy: Float = 0
                for i in frameStart..<(frameStart + frame) {
                    energy += buffer[i] * buffer[i]
                }
                if energy <= bestEnergy {
                    bestEnergy = energy
                    bestStart = frameStart
                }
                frameStart += frame
            }
        }
        return bestStart + frame / 2
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
