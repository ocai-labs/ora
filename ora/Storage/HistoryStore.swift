//
//  HistoryStore.swift
//  ora
//
//  On-disk history of recent dictations: the recorded audio plus the
//  transcript, so a failed transcription isn't lost and any entry can
//  be re-transcribed with another model. Kept on this Mac only, capped
//  at the `maxEntries` newest, and switched off (and wiped) by the
//  "Save recordings" setting.
//
//  ## Layout
//
//      <root>/index.json           [HistoryEntry], newest first
//      <root>/Audio/<uuid>.wav     16 kHz mono 16-bit PCM
//
//  Default root: ~/Library/Application Support/Ora/History.
//
//  ## Threading
//
//  The store is main-actor state (observed by the History page). All
//  file I/O — WAV writes, index writes, deletes — runs on one private
//  serial queue, so it never blocks the transcribe → paste path, and
//  FIFO order means a delete enqueued after a write always wins (no
//  orphaned audio from a cancel racing the save). Reads for
//  regenerate/playback go through the same queue, so they see every
//  write that came before them.
//

import AVFoundation
import Foundation
import Observation

struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        /// Saved, transcription still running.
        case pending
        case success
        /// Transcription failed; the audio is kept so it can be
        /// regenerated.
        case failed
    }

    let id: UUID
    let createdAt: Date
    /// Recording length in seconds.
    let duration: Double
    var modelId: String
    var modelName: String
    var text: String?
    var status: Status
    let audioFileName: String
}

@MainActor
@Observable
final class HistoryStore {
    static let maxEntries = 25

    /// ~/Library/Application Support/Ora/History.
    nonisolated static var defaultRootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ora", isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
    }

    static let shared = HistoryStore(rootDirectory: defaultRootDirectory)

    /// Newest first, at most `maxEntries`.
    private(set) var entries: [HistoryEntry] = []

    /// Entries being re-transcribed right now (transient, not saved).
    private(set) var regeneratingIDs: Set<UUID> = []

    /// Last regenerate error per entry, shown inline on its row
    /// (transient, not saved). Cleared by the next attempt.
    private(set) var regenerateErrors: [UUID: String] = [:]

    let rootDirectory: URL
    private var indexURL: URL { rootDirectory.appendingPathComponent("index.json") }
    private var audioDirectory: URL { rootDirectory.appendingPathComponent("Audio", isDirectory: true) }

    @ObservationIgnored
    private let ioQueue = DispatchQueue(label: "com.oceanai.ora.history-io", qos: .utility)

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        load()
    }

    // MARK: - Queries

    func entry(id: UUID) -> HistoryEntry? {
        entries.first { $0.id == id }
    }

    func audioURL(for entry: HistoryEntry) -> URL {
        audioDirectory.appendingPathComponent(entry.audioFileName)
    }

    // MARK: - Mutations

    /// Inserts a new entry for a just-finished recording and saves its
    /// audio in the background. Prunes to the newest `maxEntries`,
    /// deleting the evicted entries' audio. Returns immediately.
    @discardableResult
    func add(
        samples: [Float],
        modelId: String,
        modelName: String,
        status: HistoryEntry.Status = .pending,
        text: String? = nil,
        createdAt: Date = Date()
    ) -> HistoryEntry {
        let id = UUID()
        let entry = HistoryEntry(
            id: id,
            createdAt: createdAt,
            duration: Double(samples.count) / Recorder.targetSampleRate,
            modelId: modelId,
            modelName: modelName,
            text: text,
            status: status,
            audioFileName: "\(id.uuidString).wav"
        )
        let audioURL = audioURL(for: entry)
        let audioDirectory = audioDirectory
        ioQueue.async {
            do {
                try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
                try HistoryAudio.wavData(samples: samples).write(to: audioURL, options: .atomic)
            } catch {
                NSLog("[History] audio write failed: %@", String(describing: error))
            }
        }
        entries.insert(entry, at: 0)
        let evicted = entries.count > Self.maxEntries ? Array(entries[Self.maxEntries...]) : []
        if !evicted.isEmpty {
            entries.removeLast(evicted.count)
            removeAudio(of: evicted)
        }
        persist()
        return entry
    }

    /// Updates an entry's transcript / status (and, after a regenerate,
    /// its model). No-op for an unknown id (e.g. deleted meanwhile).
    func update(
        id: UUID,
        text: String?,
        status: HistoryEntry.Status,
        modelId: String? = nil,
        modelName: String? = nil
    ) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].text = text
        entries[index].status = status
        if let modelId { entries[index].modelId = modelId }
        if let modelName { entries[index].modelName = modelName }
        persist()
    }

    func delete(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let removed = entries.remove(at: index)
        regeneratingIDs.remove(id)
        regenerateErrors[id] = nil
        removeAudio(of: [removed])
        persist()
    }

    /// Deletes every entry and the whole history folder.
    func clearAll() {
        entries = []
        regeneratingIDs = []
        regenerateErrors = [:]
        let root = rootDirectory
        ioQueue.async {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - Regenerate bookkeeping

    func beginRegenerating(id: UUID) {
        regeneratingIDs.insert(id)
        regenerateErrors[id] = nil
    }

    func endRegenerating(id: UUID, error: String?) {
        regeneratingIDs.remove(id)
        // Only keep the error for an entry that still exists.
        regenerateErrors[id] = entry(id: id) == nil ? nil : error
    }

    // MARK: - Audio access

    /// Whether the entry's audio is on disk (after any pending write).
    func audioExists(for entry: HistoryEntry) async -> Bool {
        let url = audioURL(for: entry)
        return await onIOQueue { FileManager.default.fileExists(atPath: url.path) }
    }

    /// Reads the entry's audio back as 16 kHz mono Float32 samples.
    func loadSamples(for entry: HistoryEntry) async throws -> [Float] {
        let url = audioURL(for: entry)
        return try await onIOQueueThrowing {
            try HistoryAudio.samples(fromWAV: Data(contentsOf: url))
        }
    }

    /// Waits until every queued write/delete has hit the disk. For tests.
    func flush() async {
        await onIOQueue {}
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        guard var decoded = try? JSONDecoder.history.decode([HistoryEntry].self, from: data) else {
            // Corrupt index: start over rather than fail. The audio it
            // referenced can no longer be listed, so drop it too.
            NSLog("[History] index unreadable, starting empty")
            let audioDirectory = audioDirectory
            ioQueue.async { try? FileManager.default.removeItem(at: audioDirectory) }
            persist()
            return
        }
        // A pending entry at launch means the app quit mid-transcribe;
        // the audio is there, so offer it for regenerate.
        var changed = false
        for index in decoded.indices where decoded[index].status == .pending {
            decoded[index].status = .failed
            changed = true
        }
        decoded.sort { $0.createdAt > $1.createdAt }
        if decoded.count > Self.maxEntries {
            removeAudio(of: Array(decoded[Self.maxEntries...]))
            decoded.removeLast(decoded.count - Self.maxEntries)
            changed = true
        }
        entries = decoded
        if changed { persist() }
    }

    private func persist() {
        guard let data = try? JSONEncoder.history.encode(entries) else { return }
        let indexURL = indexURL
        let root = rootDirectory
        ioQueue.async {
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try data.write(to: indexURL, options: .atomic)
            } catch {
                NSLog("[History] index write failed: %@", String(describing: error))
            }
        }
    }

    private func removeAudio(of removed: [HistoryEntry]) {
        let urls = removed.map(audioURL(for:))
        ioQueue.async {
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func onIOQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume(returning: work()) }
        }
    }

    private func onIOQueueThrowing<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async { continuation.resume(with: Result { try work() }) }
        }
    }
}

private extension JSONEncoder {
    static var history: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var history: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - WAV encoding

/// Minimal 16 kHz mono 16-bit PCM WAV encode/decode for history audio.
/// Pure and nonisolated so it runs on the I/O queue.
nonisolated enum HistoryAudio {
    enum Failure: Error, LocalizedError {
        case malformed

        var errorDescription: String? { "Saved audio is unreadable" }
    }

    static let sampleRate = 16_000

    static func wavData(samples: [Float]) -> Data {
        let dataSize = samples.count * 2
        var data = Data(capacity: 44 + dataSize)
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)                         // fmt chunk size
        append16(1)                          // PCM
        append16(1)                          // mono
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))     // byte rate
        append16(2)                          // block align
        append16(16)                         // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(dataSize))
        for sample in samples {
            let clamped = max(-1, min(1, sample.isFinite ? sample : 0))
            append16(UInt16(bitPattern: Int16((clamped * Float(Int16.max)).rounded())))
        }
        return data
    }

    /// Decodes a 16-bit mono PCM WAV (as written by `wavData`) back to
    /// Float32 samples in -1...1.
    static func samples(fromWAV data: Data) throws -> [Float] {
        let bytes = [UInt8](data)
        guard bytes.count >= 12,
              String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE" else { throw Failure.malformed }
        func u32(_ at: Int) -> Int {
            Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        var offset = 12
        var isPCM16Mono = false
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let size = u32(offset + 4)
            let body = offset + 8
            if id == "fmt " {
                guard body + 16 <= bytes.count else { throw Failure.malformed }
                isPCM16Mono = u16(body) == 1 && u16(body + 2) == 1 && u16(body + 14) == 16
            } else if id == "data" {
                guard isPCM16Mono else { throw Failure.malformed }
                let end = min(bytes.count, body + size)
                var samples = [Float]()
                samples.reserveCapacity((end - body) / 2)
                var i = body
                while i + 1 < end {
                    let value = Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)
                    samples.append(Float(value) / Float(Int16.max))
                    i += 2
                }
                return samples
            }
            offset = body + size + (size & 1)
        }
        throw Failure.malformed
    }

    /// Wraps samples in the 16 kHz mono Float32 buffer every
    /// `Transcriber` expects.
    static func buffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))
        ) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
            }
        }
        return buffer
    }
}
