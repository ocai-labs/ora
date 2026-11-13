//
//  HistoryStoreTests.swift
//  oraTests
//
//  HistoryStore against a throwaway temp directory: insert, prune to
//  the newest 25 (evicted audio deleted), persist + reload, delete,
//  clear, and tolerance of a corrupt index / missing audio. Plus the
//  WAV round trip and the saveHistory default.
//

import AVFoundation
import Foundation
import Testing
@testable import ora

@MainActor
struct HistoryStoreTests {
    private func withTempRoot(_ body: (URL) async throws -> Void) async rethrows {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ora-history-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    private func tone(seconds: Double) -> [Float] {
        let count = Int(seconds * Recorder.targetSampleRate)
        return (0..<count).map { Float(sin(Double($0) * 0.05) * 0.5) }
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    @Test("add stores a pending entry and writes its audio")
    func addWritesAudio() async throws {
        try await withTempRoot { root in
            let store = HistoryStore(rootDirectory: root)
            let entry = store.add(samples: tone(seconds: 1), modelId: "m", modelName: "Model")
            await store.flush()

            #expect(store.entries.count == 1)
            #expect(entry.status == .pending)
            #expect(abs(entry.duration - 1) < 0.001)
            #expect(fileExists(store.audioURL(for: entry)))
            #expect(await store.audioExists(for: entry))
            let samples = try await store.loadSamples(for: entry)
            #expect(samples.count == Int(Recorder.targetSampleRate))
        }
    }

    @Test("prunes to the newest 25 and deletes evicted audio")
    func prunes() async {
        await withTempRoot { root in
            let store = HistoryStore(rootDirectory: root)
            var added: [HistoryEntry] = []
            for i in 0..<(HistoryStore.maxEntries + 2) {
                added.append(store.add(
                    samples: tone(seconds: 0.1), modelId: "m", modelName: "M",
                    createdAt: Date(timeIntervalSince1970: Double(i))
                ))
            }
            await store.flush()

            #expect(store.entries.count == HistoryStore.maxEntries)
            #expect(store.entries.first?.id == added.last?.id)
            #expect(store.entry(id: added[0].id) == nil)
            #expect(store.entry(id: added[1].id) == nil)
            #expect(!fileExists(store.audioURL(for: added[0])))
            #expect(!fileExists(store.audioURL(for: added[1])))
            #expect(fileExists(store.audioURL(for: added[2])))
        }
    }

    @Test("updates persist and reload; pending becomes failed on reload")
    func persistReload() async {
        await withTempRoot { root in
            let store = HistoryStore(rootDirectory: root)
            let a = store.add(samples: tone(seconds: 0.5), modelId: "m1", modelName: "One",
                              createdAt: Date(timeIntervalSince1970: 1))
            let b = store.add(samples: tone(seconds: 0.5), modelId: "m1", modelName: "One",
                              createdAt: Date(timeIntervalSince1970: 2))
            store.update(id: a.id, text: "hello", status: .success, modelId: "m2", modelName: "Two")
            await store.flush()

            let reloaded = HistoryStore(rootDirectory: root)
            #expect(reloaded.entries.map(\.id) == [b.id, a.id])
            let reloadedA = reloaded.entry(id: a.id)
            #expect(reloadedA?.text == "hello")
            #expect(reloadedA?.status == .success)
            #expect(reloadedA?.modelName == "Two")
            #expect(reloaded.entry(id: b.id)?.status == .failed)
        }
    }

    @Test("delete removes the entry and its audio")
    func deleteOne() async {
        await withTempRoot { root in
            let store = HistoryStore(rootDirectory: root)
            let a = store.add(samples: tone(seconds: 0.5), modelId: "m", modelName: "M")
            let b = store.add(samples: tone(seconds: 0.5), modelId: "m", modelName: "M")
            store.delete(id: a.id)
            await store.flush()

            #expect(store.entries.map(\.id) == [b.id])
            #expect(!fileExists(store.audioURL(for: a)))
            #expect(HistoryStore(rootDirectory: root).entries.map(\.id) == [b.id])
        }
    }

    @Test("clearAll removes everything on disk")
    func clearAll() async {
        await withTempRoot { root in
            let store = HistoryStore(rootDirectory: root)
            store.add(samples: tone(seconds: 0.5), modelId: "m", modelName: "M")
            store.clearAll()
            await store.flush()

            #expect(store.entries.isEmpty)
            #expect(!fileExists(root))
            #expect(HistoryStore(rootDirectory: root).entries.isEmpty)

            // Still usable after a clear.
            let again = store.add(samples: tone(seconds: 0.5), modelId: "m", modelName: "M")
            await store.flush()
            #expect(fileExists(store.audioURL(for: again)))
        }
    }

    @Test("a corrupt index starts empty instead of failing")
    func corruptIndex() async throws {
        try await withTempRoot { root in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("not json".utf8).write(to: root.appendingPathComponent("index.json"))

            let store = HistoryStore(rootDirectory: root)
            #expect(store.entries.isEmpty)
            store.add(samples: tone(seconds: 0.5), modelId: "m", modelName: "M")
            await store.flush()
            #expect(HistoryStore(rootDirectory: root).entries.count == 1)
        }
    }

    @Test("a missing audio file is reported, not fatal")
    func missingAudio() async throws {
        try await withTempRoot { root in
            let store = HistoryStore(rootDirectory: root)
            let entry = store.add(samples: tone(seconds: 0.5), modelId: "m", modelName: "M")
            await store.flush()
            try FileManager.default.removeItem(at: store.audioURL(for: entry))

            #expect(await store.audioExists(for: entry) == false)
            await #expect(throws: (any Error).self) {
                _ = try await store.loadSamples(for: entry)
            }
            #expect(HistoryStore(rootDirectory: root).entries.count == 1)
        }
    }

    @Test("regenerate bookkeeping keeps errors only for live entries")
    func regenerateBookkeeping() async {
        await withTempRoot { root in
            let store = HistoryStore(rootDirectory: root)
            let entry = store.add(samples: tone(seconds: 0.5), modelId: "m", modelName: "M")
            store.beginRegenerating(id: entry.id)
            #expect(store.regeneratingIDs.contains(entry.id))
            store.endRegenerating(id: entry.id, error: "Boom")
            #expect(!store.regeneratingIDs.contains(entry.id))
            #expect(store.regenerateErrors[entry.id] == "Boom")
            store.beginRegenerating(id: entry.id)
            #expect(store.regenerateErrors[entry.id] == nil)
            store.delete(id: entry.id)
            store.endRegenerating(id: entry.id, error: "Late")
            #expect(store.regenerateErrors[entry.id] == nil)
            await store.flush()
        }
    }

    @Test("WAV encode/decode round-trips within 16-bit precision")
    func wavRoundTrip() throws {
        let samples: [Float] = [0, 0.5, -0.5, 1, -1, 0.25, 2, -3]
        let data = HistoryAudio.wavData(samples: samples)
        #expect(data.count == 44 + samples.count * 2)
        let decoded = try HistoryAudio.samples(fromWAV: data)
        let expected: [Float] = [0, 0.5, -0.5, 1, -1, 0.25, 1, -1]
        #expect(decoded.count == expected.count)
        for (a, b) in zip(decoded, expected) { #expect(abs(a - b) < 0.0001) }
        #expect(throws: (any Error).self) { _ = try HistoryAudio.samples(fromWAV: Data("junk".utf8)) }

        let buffer = try #require(HistoryAudio.buffer(from: decoded))
        #expect(Int(buffer.frameLength) == decoded.count)
        #expect(buffer.format.sampleRate == Recorder.targetSampleRate)
    }

    @Test("saveHistory defaults on and persists")
    func saveHistoryPreference() {
        let suiteName = "ora.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = Preferences(defaults: defaults)
        #expect(prefs.saveHistory)
        prefs.saveHistory = false
        #expect(Preferences(defaults: defaults).saveHistory == false)
    }
}
