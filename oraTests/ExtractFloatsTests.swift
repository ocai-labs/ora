//
//  ExtractFloatsTests.swift
//  oraTests
//
//  Tests for AVAudioPCMBuffer.monoSamples() — the shared extension that
//  replaced the identical extractFloats(from:) in each transcriber.
//

import Testing
import AVFoundation
@testable import ora

struct ExtractFloatsTests {

    // MARK: - Helpers

    /// Creates a mono Float32 PCM buffer at 16 kHz and fills channel 0
    /// with the provided samples.
    private func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(max(samples.count, 1))
        )!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if !samples.isEmpty, let channel = buffer.floatChannelData?[0] {
            for (i, s) in samples.enumerated() { channel[i] = s }
        }
        return buffer
    }

    // MARK: - Tests

    @Test func knownSamples() {
        let input: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
        let buffer = makeBuffer(input)
        let result = buffer.monoSamples()
        #expect(result == input)
    }

    @Test func emptyBuffer() {
        let buffer = makeBuffer([])
        let result = buffer.monoSamples()
        #expect(result.isEmpty)
    }

    @Test func singleSample() {
        let input: [Float] = [0.42]
        let buffer = makeBuffer(input)
        let result = buffer.monoSamples()
        #expect(result == input)
    }

    @Test func largeBuffer() {
        let input = (0..<4096).map { Float($0) / 4096.0 }
        let buffer = makeBuffer(input)
        let result = buffer.monoSamples()
        #expect(result == input)
    }

    @Test func negativeValues() {
        let input: [Float] = [-1.0, -0.5, 0.0, 0.5, 1.0]
        let buffer = makeBuffer(input)
        let result = buffer.monoSamples()
        #expect(result == input)
    }
}
