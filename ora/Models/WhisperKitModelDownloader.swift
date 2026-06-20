//
//  WhisperKitModelDownloader.swift
//  ora
//
//  Adapter for downloading WhisperKit CoreML models from HuggingFace.
//  Mirrors the MLXModelDownloader interface so ModelManager can route
//  to any downloader without knowing the underlying SDK.
//
//  This and WhisperKitTranscriber are the only files that import
//  WhisperKit — keeping the SDK isolated to these two adapters means
//  the rest of the app talks to plain Swift types.
//
//  ## Cache location
//
//  WhisperKit's HubApi downloads models to:
//
//    ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/<variant>/
//
//  We replicate this path for isInstalled and cacheDirectory so the
//  downloader and transcriber agree on where models live.
//
//  ## Progress tracking
//
//  Unlike MLXModelDownloader (which uses filesystem polling), we use
//  WhisperKit's built-in `progressCallback` from `WhisperKit.download()`.
//  This gives us a `Progress` object with accurate `fractionCompleted`
//  that tracks in-flight downloads — filesystem polling misses temp
//  files and only sees completed blobs.
//

import Foundation
import WhisperKit

struct WhisperKitModelDownloader {
    enum Failure: Error, LocalizedError {
        case unsupportedModel(String)
        case downloadFailed(Error)
        case downloadIncomplete

        var errorDescription: String? {
            switch self {
            case .unsupportedModel(let id):
                return "Model '\(id)' is not supported in this build."
            case .downloadFailed(let error):
                return "Download failed: \(error.localizedDescription)"
            case .downloadIncomplete:
                return "Download finished with files missing. Try again."
            }
        }
    }

    private func config(for id: String) throws -> WhisperKitModelConfig.Entry {
        guard let entry = WhisperKitModelConfig.models[id] else {
            throw Failure.unsupportedModel(id)
        }
        return entry
    }

    /// The directory where WhisperKit stores downloaded CoreML models.
    ///
    /// WhisperKit's HubApi defaults to:
    ///   ~/Documents/huggingface/models/<repo>/<variant>
    ///
    /// We replicate this path so `isInstalled` and the ETA poller
    /// agree with where `WhisperKit.download(variant:from:)` writes.
    private static func modelDir(for variant: String) -> URL {
        let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first!
        return documents
            .appendingPathComponent("huggingface/models")
            .appendingPathComponent(WhisperKitModelConfig.repo)
            .appendingPathComponent(variant)
    }
}

// MARK: - Install checks

extension WhisperKitModelDownloader {
    /// Returns true when the model's cache directory looks installed.
    func isInstalled(_ id: String) -> Bool {
        guard let entry = WhisperKitModelConfig.models[id] else { return false }
        return Self.installationComplete(in: Self.modelDir(for: entry.variant))
    }

    /// The compiled CoreML components every argmax whisperkit-coreml
    /// variant ships. (TextDecoderContextPrefill.mlmodelc exists for
    /// some variants but is optional, so it isn't required here.)
    static let requiredComponents = [
        "MelSpectrogram.mlmodelc",
        "AudioEncoder.mlmodelc",
        "TextDecoder.mlmodelc",
    ]

    /// Whether a model directory contains a complete installation:
    /// all three compiled components present, each with its
    /// `coremldata.bin` (HubApi downloads file-by-file, so a killed
    /// download can leave a component directory existing but hollow).
    /// Pure (over the filesystem at `dir`) — extracted so the check is
    /// unit-testable against a temp directory. Used both by the
    /// preflight `isInstalled` and as the post-download verification.
    static func installationComplete(in dir: URL) -> Bool {
        let fm = FileManager.default
        return Self.requiredComponents.allSatisfy { component in
            fm.fileExists(
                atPath: dir
                    .appendingPathComponent(component)
                    .appendingPathComponent("coremldata.bin")
                    .path
            )
        }
    }

    /// Returns the local cache directory for the model.
    func cacheDirectory(_ id: String) -> URL? {
        guard let entry = WhisperKitModelConfig.models[id] else { return nil }
        return Self.modelDir(for: entry.variant)
    }
}

// MARK: - Download

extension WhisperKitModelDownloader {
    /// Downloads the model identified by `id`, calling `onProgress` on the
    /// main actor with `.downloading(eta:)` updates from WhisperKit's
    /// built-in progress callback.
    func download(
        _ id: String,
        onProgress: @escaping @MainActor (ModelEntry.Status) -> Void
    ) async throws {
        let entry = try config(for: id)

        await MainActor.run { onProgress(.downloading(fraction: nil, eta: nil)) }

        // Track progress via WhisperKit's callback — gives us accurate
        // fractionCompleted that includes in-flight temp files.
        let startTime = Date()
        var lastFraction: Double = 0

        do {
            _ = try await WhisperKit.download(
                variant: entry.variant,
                from: WhisperKitModelConfig.repo
            ) { progress in
                let fraction = progress.fractionCompleted
                // Avoid spamming identical updates
                guard fraction > lastFraction + 0.005 else { return }
                lastFraction = fraction

                let elapsed = Date().timeIntervalSince(startTime)
                let eta: TimeInterval?
                if fraction > 0.01, elapsed > 2 {
                    let remaining = elapsed / fraction * (1.0 - fraction)
                    eta = remaining
                } else {
                    eta = nil
                }

                Task { @MainActor in
                    onProgress(.downloading(fraction: fraction, eta: eta))
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.downloadFailed(error)
        }

        // WhisperKit.download returning is not proof the variant is
        // whole (FluidAudio gets the same treatment via modelsExist).
        // Without this, a silent partial result becomes a permanently
        // "installed" broken model that fails at pipeline init.
        guard Self.installationComplete(in: Self.modelDir(for: entry.variant)) else {
            throw Failure.downloadIncomplete
        }
    }
}
