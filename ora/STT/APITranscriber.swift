//
//  APITranscriber.swift
//  ora
//
//  Cloud `Transcriber` for OpenAI-compatible /audio/transcriptions
//  endpoints. Both OpenAI and Groq speak the same multipart shape
//  (model + file fields, Bearer auth), so one implementation covers
//  both — only the base URL and the stored key/model differ.
//
//  ## Pipeline
//
//   1. Pull the PCM buffer from Recorder (16 kHz mono Float32).
//   2. Encode to an AAC/m4a temp file via AVAudioFile — ~10x smaller
//      than WAV, fine for hold-to-talk where recordings are seconds.
//   3. POST multipart/form-data with Bearer auth.
//   4. Decode `{ "text": "..." }` from the JSON response.
//
//  ## Credentials
//
//  API keys live in the Keychain (`KeychainStore`), keyed by provider
//  id. The chosen model name (e.g. "gpt-4o-transcribe",
//  "whisper-large-v3") lives in UserDefaults at `api.<id>.model` since
//  it's not a secret. Both are populated by `APIModelCard`'s settings
//  sheet.
//

import AVFoundation
import Foundation

final class APITranscriber: Transcriber {
    enum Failure: Error, LocalizedError {
        case missingAPIKey
        case missingModel
        case emptyAudio
        case encodingFailed(Error)
        case network(Error)
        case httpStatus(Int, String)
        case decodingFailed

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Add your API key in Settings ▸ Models."
            case .missingModel:
                return "Set a model name in Settings ▸ Models."
            case .emptyAudio:
                return "The recording was empty."
            case .encodingFailed(let error):
                return "Couldn't encode audio: \(error.localizedDescription)"
            case .network(let error):
                return "Network error: \(error.localizedDescription)"
            case .httpStatus(let code, let body):
                let snippet = body.prefix(160)
                return "API returned \(code): \(snippet)"
            case .decodingFailed:
                return "Couldn't parse the API response."
            }
        }
    }

    struct Provider: Equatable {
        let id: String
        let endpoint: URL
    }

    /// Returns the supported provider for a catalog id, or `nil` if
    /// we don't know how to talk to that one. New providers (Deepgram,
    /// ElevenLabs, etc.) plug in here.
    static func provider(for id: String) -> Provider? {
        switch id {
        case "openai-api":
            return Provider(
                id: id,
                endpoint: URL(string: "https://api.openai.com/v1/audio/transcriptions")!
            )
        case "groq-api":
            return Provider(
                id: id,
                endpoint: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
            )
        default:
            return nil
        }
    }

    /// UserDefaults key for the model name (non-secret) paired with a provider.
    static func modelDefaultsKey(for providerId: String) -> String {
        "api.\(providerId).model"
    }

    private let provider: Provider
    private let urlSession: URLSession

    init(provider: Provider, urlSession: URLSession? = nil) {
        self.provider = provider
        self.urlSession = urlSession ?? Self.defaultSession()
    }

    /// Builds the default URLSession for cloud transcription requests.
    ///
    /// `URLSession.shared`'s defaults are too permissive for this use
    /// case: `timeoutIntervalForResource` is 7 days. If the upstream
    /// API stalls mid-response (half-open TCP after a Wi-Fi flip, or
    /// the provider hangs the connection), the request would sit
    /// pending for days while the coordinator stays in `.transcribing`
    /// and silently ignores re-presses. A short, explicit timeout makes
    /// stalls surface as a normal error pill within a minute.
    ///
    /// `timeoutIntervalForRequest` (60s) governs the gap between bytes;
    /// dictation requests typically complete in 1–5s, so 60s already
    /// accommodates very slow uploads. `timeoutIntervalForResource`
    /// (120s) caps total request lifetime — even pathological slowness
    /// should finish or fail well within that window.
    private static func defaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    // MARK: - Transcriber

    /// No-op: there is nothing to warm up for a cloud endpoint, and the
    /// default (a silent inference) would burn a real API request — and
    /// cost — on every model selection. Overrides the protocol default.
    func prewarm() async {}

    func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String {
        guard buffer.frameLength > 0 else { throw Failure.emptyAudio }

        guard let apiKey = KeychainStore.apiKey(provider: provider.id) else {
            throw Failure.missingAPIKey
        }
        let modelName = UserDefaults.standard.string(forKey: Self.modelDefaultsKey(for: provider.id)) ?? ""
        guard !modelName.isEmpty else { throw Failure.missingModel }

        // AAC encode + file read + multipart assembly run off the main
        // actor: encoding a multi-minute recording is a 100 ms+ stall
        // that would freeze the overlay and event-tap handling (same
        // hazard class as the multi-day-freeze fix). The buffer is
        // owned by this call and untouched on main while the detached
        // work runs, hence the nonisolated(unsafe) hand-off.
        let boundary = "ora-\(UUID().uuidString)"
        nonisolated(unsafe) let pcm = buffer
        let httpBody: Data
        do {
            httpBody = try await Task.detached {
                let fileURL = try Self.writeAAC(buffer: pcm)
                defer { try? FileManager.default.removeItem(at: fileURL) }
                let audioData = try Data(contentsOf: fileURL)
                return Self.multipartBody(boundary: boundary, model: modelName, audio: audioData)
            }.value
        } catch {
            throw Failure.encodingFailed(error)
        }

        var request = URLRequest(url: provider.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = httpBody

        // The encode + file I/O above aren't cancellation points; a
        // dictation cancelled during them shouldn't still hit the API.
        try Task.checkCancellation()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            throw Failure.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            // A non-HTTP response is a transport-level anomaly, not a
            // parsing problem — label it as such.
            throw Failure.network(URLError(.badServerResponse))
        }
        if !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw Failure.httpStatus(http.statusCode, body)
        }

        struct Body: Decodable { let text: String }
        do {
            let decoded = try JSONDecoder().decode(Body.self, from: data)
            return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            // Keep the debugging signal a schema mismatch would
            // otherwise swallow: the decode error plus a body prefix.
            let prefix = String(decoding: data.prefix(200), as: UTF8.self)
            NSLog("[APITranscriber] response decode failed: \(error); body: \(prefix)")
            throw Failure.decodingFailed
        }
    }

    // MARK: - Encoding

    /// Writes a Float32 mono 16 kHz PCM buffer into a temporary AAC
    /// (.m4a) file and returns its URL. AVAudioFile handles the PCM→AAC
    /// conversion internally via ExtAudioFile; the processing format it
    /// exposes matches the input buffer so `write(from:)` is a direct
    /// feed. Caller owns the file and is responsible for deletion.
    ///
    /// Nonisolated so the encode runs on whatever (background) context
    /// calls it; internal (not private) so the encode round-trip is
    /// unit-testable.
    nonisolated static func writeAAC(buffer: AVAudioPCMBuffer) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ora-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: buffer.format.sampleRate,
            AVNumberOfChannelsKey: Int(buffer.format.channelCount),
            AVEncoderBitRateKey: 32000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
        return url
    }

    // MARK: - Multipart

    // Nonisolated for the same reason as writeAAC; internal so the
    // body framing is unit-testable.
    nonisolated static func multipartBody(boundary: String, model: String, audio: Data) -> Data {
        var body = Data()
        func append(_ s: String) {
            if let d = s.data(using: .utf8) { body.append(d) }
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(model)\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        append("json\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n")
        append("Content-Type: audio/mp4\r\n\r\n")
        body.append(audio)
        append("\r\n")

        append("--\(boundary)--\r\n")
        return body
    }
}
