//
//  EstimateEtaTests.swift
//  oraTests
//
//  Locks down the sliding-window ETA calculation used by
//  FluidAudioDownloader and MLXModelDownloader. This function is being
//  extracted to DownloadProgressUtils — these tests verify the contract
//  is preserved after the move.
//

import Foundation
import Testing
@testable import ora

@MainActor
struct EstimateEtaTests {

    // MARK: - Happy path

    @Test("steady download speed produces correct ETA")
    func steadySpeed() {
        let now = Date()
        let samples: [(t: Date, bytes: Int64)] = [
            (t: now, bytes: 100_000),
            (t: now.addingTimeInterval(10), bytes: 200_000),
        ]
        let eta = DownloadProgressUtils.estimateEta(
            samples: samples, totalBytes: 500_000
        )
        // Speed = 100_000 bytes / 10s = 10_000 bytes/s
        // Remaining = 500_000 - 200_000 = 300_000 bytes
        // ETA = 300_000 / 10_000 = 30s
        #expect(eta == 30.0)
    }

    @Test("multiple samples uses first and last for speed calculation")
    func multiSampleSlidingWindow() {
        let now = Date()
        let samples: [(t: Date, bytes: Int64)] = [
            (t: now, bytes: 0),
            (t: now.addingTimeInterval(2), bytes: 50_000),
            (t: now.addingTimeInterval(4), bytes: 100_000),
            (t: now.addingTimeInterval(6), bytes: 200_000),
        ]
        let eta = DownloadProgressUtils.estimateEta(
            samples: samples, totalBytes: 1_000_000
        )
        // Speed = (200_000 - 0) / 6s = 33_333.33 bytes/s
        // Remaining = 1_000_000 - 200_000 = 800_000
        // ETA = 800_000 / 33_333.33 ≈ 24s
        #expect(eta != nil)
        #expect(abs(eta! - 24.0) < 0.1)
    }

    @Test("download nearly complete returns small ETA")
    func nearlyComplete() {
        let now = Date()
        let samples: [(t: Date, bytes: Int64)] = [
            (t: now, bytes: 900_000),
            (t: now.addingTimeInterval(1), bytes: 990_000),
        ]
        let eta = DownloadProgressUtils.estimateEta(
            samples: samples, totalBytes: 1_000_000
        )
        // Speed = 90_000 bytes/s, remaining = 10_000
        // ETA = 10_000 / 90_000 ≈ 0.111s
        #expect(eta != nil)
        #expect(eta! < 1.0)
    }

    @Test("already-complete download returns zero ETA")
    func alreadyComplete() {
        let now = Date()
        let samples: [(t: Date, bytes: Int64)] = [
            (t: now, bytes: 400_000),
            (t: now.addingTimeInterval(5), bytes: 500_000),
        ]
        let eta = DownloadProgressUtils.estimateEta(
            samples: samples, totalBytes: 500_000
        )
        // Remaining = 0, so ETA = 0
        #expect(eta == 0.0)
    }

    // MARK: - Edge cases that return nil

    @Test("single sample returns nil")
    func singleSample() {
        let eta = DownloadProgressUtils.estimateEta(
            samples: [(t: Date(), bytes: 100)],
            totalBytes: 1000
        )
        #expect(eta == nil)
    }

    @Test("empty samples returns nil")
    func emptySamples() {
        let eta = DownloadProgressUtils.estimateEta(
            samples: [],
            totalBytes: 1000
        )
        #expect(eta == nil)
    }

    @Test("zero totalBytes returns nil")
    func zeroTotalBytes() {
        let now = Date()
        let eta = DownloadProgressUtils.estimateEta(
            samples: [
                (t: now, bytes: 100),
                (t: now.addingTimeInterval(1), bytes: 200),
            ],
            totalBytes: 0
        )
        #expect(eta == nil)
    }

    @Test("no progress between samples returns nil")
    func noProgress() {
        let now = Date()
        let eta = DownloadProgressUtils.estimateEta(
            samples: [
                (t: now, bytes: 100),
                (t: now.addingTimeInterval(5), bytes: 100),
            ],
            totalBytes: 1000
        )
        #expect(eta == nil)
    }

    @Test("same timestamp returns nil")
    func sameTimestamp() {
        let now = Date()
        let eta = DownloadProgressUtils.estimateEta(
            samples: [
                (t: now, bytes: 100),
                (t: now, bytes: 200),
            ],
            totalBytes: 1000
        )
        #expect(eta == nil)
    }

    // MARK: - Non-negative guarantee

    @Test("ETA is never negative even if bytes exceed totalBytes")
    func neverNegative() {
        let now = Date()
        let eta = DownloadProgressUtils.estimateEta(
            samples: [
                (t: now, bytes: 400_000),
                (t: now.addingTimeInterval(5), bytes: 600_000),
            ],
            totalBytes: 500_000
        )
        // last.bytes (600k) > totalBytes (500k) → remaining = max(0, -100k) = 0
        #expect(eta != nil)
        #expect(eta! >= 0)
    }
}
