//
//  ModelInstallCheckTests.swift
//  oraTests
//
//  Exercises the per-backend "does this directory contain a complete
//  model installation?" checks against temp directories. These locked
//  in review finding #1 as known issues until the checks were
//  strengthened; they now assert the fixed behavior: an interrupted
//  download that landed only part of a model must NOT be reported as
//  installed (it used to seed `.downloaded` on the next launch and
//  then fail at model-load time).
//

import Foundation
import Testing
@testable import ora

@MainActor
struct ModelInstallCheckTests {

    /// Creates a unique temp directory, runs `body` with it, and
    /// removes it afterwards.
    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ora-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    /// Creates a compiled-model-shaped component directory
    /// (`<name>.mlmodelc/coremldata.bin`) under `dir`.
    private func makeComponent(_ name: String, in dir: URL, hollow: Bool = false) throws {
        let component = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: component, withIntermediateDirectories: false)
        if !hollow {
            try Data([0x01]).write(to: component.appendingPathComponent("coremldata.bin"))
        }
    }

    // MARK: - WhisperKit

    @Test("WhisperKit: missing or empty directory is not installed")
    func whisperKitEmptyNotInstalled() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ora-tests-missing-\(UUID().uuidString)")
        #expect(!WhisperKitModelDownloader.installationComplete(in: missing))

        try withTempDir { dir in
            #expect(!WhisperKitModelDownloader.installationComplete(in: dir))
        }
    }

    @Test("WhisperKit: full component set is installed")
    func whisperKitCompleteInstalled() throws {
        try withTempDir { dir in
            for component in WhisperKitModelDownloader.requiredComponents {
                try makeComponent(component, in: dir)
            }
            try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
            #expect(WhisperKitModelDownloader.installationComplete(in: dir))
        }
    }

    @Test("WhisperKit: the optional prefill component is not required")
    func whisperKitPrefillOptional() throws {
        // Some variants ship TextDecoderContextPrefill.mlmodelc; its
        // absence must not strand otherwise-complete installs.
        try withTempDir { dir in
            for component in WhisperKitModelDownloader.requiredComponents {
                try makeComponent(component, in: dir)
            }
            #expect(WhisperKitModelDownloader.installationComplete(in: dir))
        }
    }

    @Test("WhisperKit: a single component from an interrupted download is not installed")
    func whisperKitPartialNotInstalled() throws {
        try withTempDir { dir in
            try makeComponent("MelSpectrogram.mlmodelc", in: dir)
            #expect(!WhisperKitModelDownloader.installationComplete(in: dir))
        }
    }

    @Test("WhisperKit: a hollow component directory (no coremldata.bin) is not installed")
    func whisperKitHollowComponentNotInstalled() throws {
        // HubApi downloads file-by-file: a kill mid-component leaves
        // the .mlmodelc directory existing but missing its core blob.
        try withTempDir { dir in
            try makeComponent("MelSpectrogram.mlmodelc", in: dir)
            try makeComponent("AudioEncoder.mlmodelc", in: dir)
            try makeComponent("TextDecoder.mlmodelc", in: dir, hollow: true)
            #expect(!WhisperKitModelDownloader.installationComplete(in: dir))
        }
    }

    // MARK: - MLX

    @Test("MLX: missing or empty directory is not installed")
    func mlxEmptyNotInstalled() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ora-tests-missing-\(UUID().uuidString)")
        #expect(!MLXModelDownloader.installationComplete(in: missing))

        try withTempDir { dir in
            #expect(!MLXModelDownloader.installationComplete(in: dir))
        }
    }

    @Test("MLX: zero-byte weights are not installed")
    func mlxZeroByteWeightsNotInstalled() throws {
        try withTempDir { dir in
            try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
            try Data("{}".utf8).write(to: dir.appendingPathComponent("tokenizer.json"))
            FileManager.default.createFile(
                atPath: dir.appendingPathComponent("model.safetensors").path,
                contents: nil
            )
            #expect(!MLXModelDownloader.installationComplete(in: dir))
        }
    }

    @Test("MLX: weights + config + tokenizer is installed")
    func mlxCompleteInstalled() throws {
        try withTempDir { dir in
            try Data([0x01]).write(to: dir.appendingPathComponent("model.safetensors"))
            try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
            try Data("{}".utf8).write(to: dir.appendingPathComponent("tokenizer.json"))
            #expect(MLXModelDownloader.installationComplete(in: dir))
        }
    }

    @Test("MLX: tokenizer_config.json alone satisfies the tokenizer requirement")
    func mlxTokenizerConfigAccepted() throws {
        try withTempDir { dir in
            try Data([0x01]).write(to: dir.appendingPathComponent("model.safetensors"))
            try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
            try Data("{}".utf8).write(to: dir.appendingPathComponent("tokenizer_config.json"))
            #expect(MLXModelDownloader.installationComplete(in: dir))
        }
    }

    @Test("MLX: weights without config/tokenizer are not installed")
    func mlxWeightsOnlyNotInstalled() throws {
        try withTempDir { dir in
            try Data([0x01]).write(to: dir.appendingPathComponent("model.safetensors"))
            #expect(!MLXModelDownloader.installationComplete(in: dir))
        }
    }

    @Test("MLX sharded checkpoint: complete when every indexed shard is present")
    func mlxShardedCompleteInstalled() throws {
        try withTempDir { dir in
            try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
            try Data("{}".utf8).write(to: dir.appendingPathComponent("tokenizer.json"))
            let index = """
            {"weight_map": {"a.weight": "model-00001-of-00002.safetensors",
                            "b.weight": "model-00002-of-00002.safetensors"}}
            """
            try Data(index.utf8).write(to: dir.appendingPathComponent("model.safetensors.index.json"))
            try Data([0x01]).write(to: dir.appendingPathComponent("model-00001-of-00002.safetensors"))
            try Data([0x01]).write(to: dir.appendingPathComponent("model-00002-of-00002.safetensors"))
            #expect(MLXModelDownloader.installationComplete(in: dir))
        }
    }

    @Test("MLX sharded checkpoint: a missing shard is not installed even with other weights present")
    func mlxShardedMissingShardNotInstalled() throws {
        // This is the exact 1.7B failure mode: one shard copied, the
        // app killed, and the lone .safetensors used to satisfy the
        // old any-non-zero-weights check.
        try withTempDir { dir in
            try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
            try Data("{}".utf8).write(to: dir.appendingPathComponent("tokenizer.json"))
            let index = """
            {"weight_map": {"a.weight": "model-00001-of-00002.safetensors",
                            "b.weight": "model-00002-of-00002.safetensors"}}
            """
            try Data(index.utf8).write(to: dir.appendingPathComponent("model.safetensors.index.json"))
            try Data([0x01]).write(to: dir.appendingPathComponent("model-00001-of-00002.safetensors"))
            #expect(!MLXModelDownloader.installationComplete(in: dir))
        }
    }
}
