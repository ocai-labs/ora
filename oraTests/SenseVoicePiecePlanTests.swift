//
//  SenseVoicePiecePlanTests.swift
//  oraTests
//
//  Locks down SenseVoiceTranscriber's piece planning. The CoreML
//  preprocessor only accepts 0.2 s .. 30 s of audio (RangeDims
//  [3200, 480000] at 16 kHz); the old planner cut 90 s pieces, so every
//  dictation over 30 s threw and was silently dropped. Every plan here
//  must cover the buffer exactly, with no piece outside those bounds
//  (bar a lone too-short buffer, which the transcriber pads).
//

import Foundation
import Testing
@testable import ora

struct SenseVoicePiecePlanTests {
    private typealias SV = SenseVoiceTranscriber
    private static let second = 16_000

    /// Contiguous, gap-free, starts at 0, ends at `count`.
    private func expectCovers(_ ranges: [Range<Int>], count: Int) {
        #expect(ranges.first?.lowerBound == 0)
        #expect(ranges.last?.upperBound == count)
        for (a, b) in zip(ranges, ranges.dropFirst()) {
            #expect(a.upperBound == b.lowerBound)
        }
    }

    private func expectWithinPreprocessorBounds(_ ranges: [Range<Int>]) {
        for range in ranges {
            #expect(range.count >= SV.minPieceSamples, "piece \(range) below 0.2 s")
            #expect(range.count <= SV.maxPieceSamples, "piece \(range) above 30 s")
        }
    }

    @Test("constants match the preprocessor's RangeDims [3200, 480000]")
    func constants() {
        #expect(SV.minPieceSamples == 3_200)
        #expect(SV.maxPieceSamples == 480_000)
        #expect(SV.targetPieceSamples + SV.minPieceSamples <= SV.maxPieceSamples)
    }

    @Test("empty buffer plans no pieces")
    func empty() {
        #expect(SV.planPieces(count: 0).isEmpty)
    }

    @Test("buffers up to 30 s stay whole (including exactly 30 s)")
    func shortStaysWhole() {
        for count in [1, 3_199, 3_200, 5 * Self.second, 25 * Self.second, 480_000] {
            #expect(SV.planPieces(count: count) == [0..<count])
        }
    }

    @Test("30 s + 1 sample splits, and the tail is far above the 0.2 s floor")
    func justOverLimit() {
        let count = 480_001
        let ranges = SV.planPieces(count: count)
        #expect(ranges == [0..<400_000, 400_000..<count])
        expectWithinPreprocessorBounds(ranges)
    }

    @Test("long buffers split into valid pieces with the default (no-pause) cut")
    func longBuffersDefaultCut() {
        let counts = [
            31 * Self.second, 45 * Self.second, 55 * Self.second + 1, 60 * Self.second,
            90 * Self.second, 108 * Self.second, 10 * 60 * Self.second + 123,
        ]
        for count in counts {
            let ranges = SV.planPieces(count: count)
            expectCovers(ranges, count: count)
            expectWithinPreprocessorBounds(ranges)
            #expect(ranges.count >= 2)
        }
    }

    @Test("every count in a sweep around the boundaries plans valid pieces")
    func sweep() {
        var count = 470_000
        while count < 1_500_000 {
            let ranges = SV.planPieces(count: count)
            expectCovers(ranges, count: count)
            expectWithinPreprocessorBounds(ranges)
            count += 997
        }
    }

    @Test("the cut callback picks the boundary inside [target − 5 s, target]")
    func cutWindow() {
        var windows: [ClosedRange<Int>] = []
        let ranges = SV.planPieces(count: 60 * Self.second) { window in
            windows.append(window)
            return window.lowerBound   // cut as early as allowed
        }
        #expect(windows.first == (20 * Self.second)...(25 * Self.second))
        #expect(ranges.first == 0..<(20 * Self.second))
        expectCovers(ranges, count: 60 * Self.second)
        expectWithinPreprocessorBounds(ranges)
    }

    @Test("a cut callback returning out-of-window values is clamped")
    func cutIsClamped() {
        for bogus in [Int.min, -5, 0, 1, Int.max] {
            let count = 70 * Self.second
            let ranges = SV.planPieces(count: count) { _ in bogus }
            expectCovers(ranges, count: count)
            expectWithinPreprocessorBounds(ranges)
            for range in ranges.dropLast() {
                #expect(range.count >= 20 * Self.second && range.count <= 25 * Self.second)
            }
        }
    }

    // MARK: - quietestPoint

    @Test("quietestPoint finds the silent gap inside the window")
    func quietestPointFindsSilence() {
        var samples = [Float](repeating: 0.5, count: 30 * Self.second)
        // 100 ms of silence at 22.0 s.
        let gap = 22 * Self.second
        for i in gap..<(gap + 1_600) { samples[i] = 0 }
        let point = SV.quietestPoint(in: samples, within: (20 * Self.second)...(25 * Self.second))
        #expect(point >= gap && point < gap + 1_600)
    }

    @Test("quietestPoint prefers the later frame on ties (keeps pieces long)")
    func quietestPointTiesGoLate() {
        let samples = [Float](repeating: 0, count: 10_000)
        let point = SV.quietestPoint(in: samples, within: 0...6_400, frame: 320)
        #expect(point == 6_400 - 320 + 160)
    }

    @Test("quietestPoint falls back to the upper bound when no frame fits")
    func quietestPointFallback() {
        let samples = [Float](repeating: 0, count: 100)
        #expect(SV.quietestPoint(in: samples, within: 0...5_000) == 5_000)
        #expect(SV.quietestPoint(in: samples, within: 10...20) == 20)
    }

    @Test("planning with quietestPoint cuts long speech at the pauses")
    func planCutsAtPauses() {
        let count = 50 * Self.second
        var samples = (0..<count).map { Float(sin(Double($0) * 0.05)) * 0.3 }
        let gap = 23 * Self.second
        for i in gap..<(gap + 3_200) { samples[i] = 0 }
        let ranges = SV.planPieces(count: count) { SV.quietestPoint(in: samples, within: $0) }
        #expect(ranges.count == 2)
        #expect(ranges[0].upperBound >= gap && ranges[0].upperBound < gap + 3_200)
        expectCovers(ranges, count: count)
        expectWithinPreprocessorBounds(ranges)
    }
}
