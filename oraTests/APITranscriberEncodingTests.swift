//
//  APITranscriberEncodingTests.swift
//  oraTests
//
//  Locks down the two pure-ish halves of the API request that now run
//  off the main actor: the multipart body framing (OpenAI/Groq both
//  parse this shape) and the PCM→AAC encode round-trip.
//

import AVFoundation
import Testing
@testable import ora

struct APITranscriberEncodingTests {

    // MARK: - Multipart framing

    @Test("multipart body has the OpenAI-compatible shape")
    func multipartShape() {
        let audio = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let body = APITranscriber.multipartBody(
            boundary: "ora-test-boundary",
            model: "whisper-large-v3",
            audio: audio
        )
        let text = String(decoding: body, as: UTF8.self)

        #expect(text.hasPrefix("--ora-test-boundary\r\n"))
        #expect(text.contains("Content-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-large-v3\r\n"))
        #expect(text.contains("Content-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n"))
        #expect(text.contains("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n"))
        #expect(text.contains("Content-Type: audio/mp4\r\n\r\n"))
        #expect(text.hasSuffix("--ora-test-boundary--\r\n"))
        // The raw audio bytes must be embedded verbatim.
        #expect(body.range(of: audio) != nil)
    }

    @Test("audio bytes sit between the file-part header and the closing boundary")
    func audioPlacement() {
        let audio = Data(repeating: 0xAB, count: 64)
        let body = APITranscriber.multipartBody(boundary: "b", model: "m", audio: audio)

        let header = Data("Content-Type: audio/mp4\r\n\r\n".utf8)
        let closing = Data("\r\n--b--\r\n".utf8)
        guard let headerRange = body.range(of: header),
              let audioRange = body.range(of: audio),
              let closingRange = body.range(of: closing)
        else {
            Issue.record("expected all three segments present")
            return
        }
        #expect(headerRange.upperBound == audioRange.lowerBound)
        #expect(audioRange.upperBound == closingRange.lowerBound)
    }

    // MARK: - AAC encode

    @Test("writeAAC encodes a PCM buffer into a non-empty deletable .m4a")
    func aacRoundTrip() throws {
        // Half a second of 440 Hz sine at the recorder's output format.
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let frames: AVAudioFrameCount = 8_000
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            channel[i] = sinf(2 * .pi * 440 * Float(i) / 16_000) * 0.5
        }

        let url = try APITranscriber.writeAAC(buffer: buffer)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(url.pathExtension == "m4a")
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        #expect(size > 0)

        // The file must be a readable audio file with roughly the same
        // duration we fed in (AAC priming/padding allows some slack).
        let readBack = try AVAudioFile(forReading: url)
        let duration = Double(readBack.length) / readBack.fileFormat.sampleRate
        #expect(duration > 0.3 && duration < 0.8)
    }
}
