//
//  MLXModelDownloader.swift
//  ora
//
//  Adapter for downloading MLX models from HuggingFace Hub. Mirrors
//  the FluidAudioDownloader interface so ModelManager can route to
//  either downloader without knowing the underlying SDK.
//
//  This and MLXTranscriber are the only files that import mlx-audio-swift
//  types — keeping the SDK isolated to these two adapters means the rest
//  of the app talks to plain Swift types.
//
//  ## Cache location
//
//  mlx-audio-swift's `ModelUtils.resolveOrDownloadModel` stores models at:
//
//    ~/.cache/huggingface/hub/mlx-audio/<owner>_<repo>/
//
//  where the "/" in the repo ID is replaced with "_". We replicate this
//  path for `isInstalled` and `cacheDirectory` so the downloader and
//  transcriber agree on where models live.
//
//  ## Download mechanism
//
//  Rather than calling `ModelUtils.resolveOrDownloadModel` directly
//  (which requires importing `HuggingFace` types like `Repo.ID` and
//  `HubCache` that aren't linked to the app target), we call
//  `Qwen3ASRModel.fromPretrained` — it wraps the same download logic
//  and returns the loaded model as a side effect. The model itself is
//  discarded; the transcriber will load it again lazily on first use.
//
//  ## ETA polling
//
//  Same filesystem polling pattern as FluidAudioDownloader: a 2-second
//  poll sums bytes on disk and derives ETA from a sliding window.
//

import Foundation
import MLXAudioSTT

struct MLXModelDownloader {
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

    private func config(for id: String) throws -> MLXModelConfig.Entry {
        guard let entry = MLXModelConfig.models[id] else {
            throw Failure.unsupportedModel(id)
        }
        return entry
    }

    /// The directory that ModelUtils writes model files into.
    ///
    /// Mirrors the path construction in `ModelUtils.resolveOrDownloadModel`:
    ///   ~/.cache/huggingface/hub/mlx-audio/<repoId with "/" → "_">
    private static func modelDir(for repoId: String) -> URL {
        let subdir = repoId.replacingOccurrences(of: "/", with: "_")
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".cache/huggingface/hub/mlx-audio")
            .appendingPathComponent(subdir)
    }

    /// The Hub staging directory where HuggingFace SDK downloads blobs
    /// before `fromPretrained` copies them to `modelDir`.
    ///
    ///   ~/.cache/huggingface/hub/models--<owner>--<repo>/
    private static func hubStagingDir(for repoId: String) -> URL {
        let hubName = "models--" + repoId.replacingOccurrences(of: "/", with: "--")
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".cache/huggingface/hub")
            .appendingPathComponent(hubName)
    }
}

// MARK: - Install checks

extension MLXModelDownloader {
    /// Returns true when the model's cache directory looks installed.
    func isInstalled(_ id: String) -> Bool {
        guard let entry = MLXModelConfig.models[id] else { return false }
        return Self.installationComplete(in: Self.modelDir(for: entry.repoId))
    }

    /// Whether a model directory contains a complete installation:
    /// model config, a tokenizer, and the weights — all shards listed
    /// in `model.safetensors.index.json` for sharded checkpoints, or
    /// at least one non-zero `.safetensors` for single-file ones.
    /// An interrupted `fromPretrained` that copied a weight shard but
    /// not the rest must not count as installed (it fails at load).
    /// Pure (over the filesystem at `dir`) — extracted so the check is
    /// unit-testable against a temp directory. Used both by the
    /// preflight `isInstalled` and as the post-download verification.
    static func installationComplete(in dir: URL) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return false }
        let names = Set(files.map(\.lastPathComponent))

        func nonZeroFile(_ name: String) -> Bool {
            let values = try? dir.appendingPathComponent(name)
                .resourceValues(forKeys: [.fileSizeKey])
            return (values?.fileSize ?? 0) > 0
        }

        // Qwen repos ship tokenizer.json + tokenizer_config.json;
        // accept either so a packaging change doesn't strand users.
        guard nonZeroFile("config.json"),
              names.contains("tokenizer.json") || names.contains("tokenizer_config.json")
        else { return false }

        if names.contains("model.safetensors.index.json") {
            // Sharded checkpoint: the index names every weight file;
            // all of them must be present and non-empty.
            guard
                let data = try? Data(
                    contentsOf: dir.appendingPathComponent("model.safetensors.index.json")
                ),
                let index = try? JSONDecoder().decode(SafetensorsIndex.self, from: data),
                !index.weightMap.isEmpty
            else { return false }
            return Set(index.weightMap.values).allSatisfy(nonZeroFile)
        }

        return files.contains { file in
            file.pathExtension == "safetensors" && nonZeroFile(file.lastPathComponent)
        }
    }

    /// Minimal slice of HuggingFace's sharded-checkpoint index format:
    /// `weight_map` maps each tensor name to the shard file holding it.
    private struct SafetensorsIndex: Decodable {
        let weightMap: [String: String]

        enum CodingKeys: String, CodingKey {
            case weightMap = "weight_map"
        }
    }

    /// Returns the local cache directory for the model, whether or not it
    /// has been downloaded yet.
    func cacheDirectory(_ id: String) -> URL? {
        guard let entry = MLXModelConfig.models[id] else { return nil }
        return Self.modelDir(for: entry.repoId)
    }

    /// Returns the Hub staging directory (blobs cache) for the model.
    /// Must be removed alongside `cacheDirectory` to fully free disk space.
    func hubStagingDirectory(_ id: String) -> URL? {
        guard let entry = MLXModelConfig.models[id] else { return nil }
        return Self.hubStagingDir(for: entry.repoId)
    }
}

// MARK: - Download

extension MLXModelDownloader {
    /// Downloads the model identified by `id`, calling `onProgress` on the
    /// main actor with `.downloading(eta:)` updates from a filesystem poller.
    /// Throws `Failure.unsupportedModel` immediately for unknown ids,
    /// `CancellationError` when the surrounding Task is cancelled, and
    /// `Failure.downloadFailed` for all other errors.
    func download(
        _ id: String,
        onProgress: @escaping @MainActor @Sendable (ModelEntry.Status) -> Void
    ) async throws {
        let entry = try config(for: id)
        let cacheDir = Self.modelDir(for: entry.repoId)
        let stagingDir = Self.hubStagingDir(for: entry.repoId)
        let totalBytes = entry.totalBytes

        // Disk poller — sole source of .downloading(eta:) updates.
        //
        // Detached on purpose: a plain `Task` here inherits the main
        // actor, putting every 2 s recursive walk of a multi-GB model
        // tree (plus the whole shared tmp dir) on the main thread for
        // the duration of the download. Only the `onProgress` hops
        // touch main.
        let pollTask = Task.detached { [totalBytes, cacheDir, stagingDir] in
            // Snapshot CFNetworkDownload tmp files that exist BEFORE our
            // download starts, so we only count ones created by this
            // download.
            let baselineTmpFiles = DownloadProgressUtils.cfNetworkDownloadFileURLs()

            var samples: [(t: Date, bytes: Int64)] = [
                (t: Date(), bytes: Self.bytesDownloaded(cacheDir: cacheDir, stagingDir: stagingDir, excluding: baselineTmpFiles))
            ]
            await MainActor.run { onProgress(.downloading(fraction: nil, eta: nil)) }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }

                let bytes = Self.bytesDownloaded(cacheDir: cacheDir, stagingDir: stagingDir, excluding: baselineTmpFiles)
                samples.append((t: Date(), bytes: bytes))
                if samples.count > 6 { samples.removeFirst(samples.count - 6) }

                let fraction: Double? = totalBytes > 0
                    ? min(1.0, Double(bytes) / Double(totalBytes))
                    : nil
                let eta = DownloadProgressUtils.estimateEta(samples: samples, totalBytes: totalBytes)
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    onProgress(.downloading(fraction: fraction, eta: eta))
                }
            }
        }
        defer { pollTask.cancel() }

        do {
            // fromPretrained downloads and caches the model, then returns
            // the loaded model. We discard the model — the transcriber
            // will load it again lazily on first transcribe() call.
            //
            // mlx-audio-swift's ModelUtils prints noisy per-chunk progress
            // to stdout ("4541808/1010771234 files"). Redirect stdout to
            // /dev/null for the duration of the download so these don't
            // pollute the Xcode console. Our own ETA polling is unaffected
            // because it reads the filesystem, not stdout.
            // Only redirect when the original stdout was saved — if
            // dup() failed, redirecting would silence stdout for the
            // rest of the process (the defer would have nothing to
            // restore).
            let savedStdout = dup(STDOUT_FILENO)
            let devNull = open("/dev/null", O_WRONLY)
            if savedStdout >= 0, devNull >= 0 { dup2(devNull, STDOUT_FILENO) }
            if devNull >= 0 { close(devNull) }
            defer {
                if savedStdout >= 0 {
                    dup2(savedStdout, STDOUT_FILENO)
                    close(savedStdout)
                }
            }
            _ = try await Qwen3ASRModel.fromPretrained(entry.repoId)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.downloadFailed(error)
        }

        // fromPretrained returning means a model loaded, but verify
        // the on-disk copy is whole anyway — the next launch's catalog
        // seeding and every later load trust this directory.
        guard Self.installationComplete(in: cacheDir) else {
            throw Failure.downloadIncomplete
        }
    }

    // MARK: - Byte counting

    /// Total bytes downloaded:
    ///   - max(stagingDir, cacheDir): completed blobs (max avoids double-
    ///     counting hard-linked files between the two directories).
    ///   - CFNetworkDownload tmp files: in-flight URLSession downloads that
    ///     appeared after our baseline snapshot.
    // Nonisolated so the detached poll task can call it without
    // bouncing back to the main actor.
    nonisolated private static func bytesDownloaded(
        cacheDir: URL,
        stagingDir: URL,
        excluding baselineFiles: Set<URL>
    ) -> Int64 {
        max(DownloadProgressUtils.directorySize(at: stagingDir),
            DownloadProgressUtils.directorySize(at: cacheDir))
            + DownloadProgressUtils.inFlightDownloadBytes(excluding: baselineFiles)
    }
}
