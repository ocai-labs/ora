//
//  FluidAudioDownloader.swift
//  ora
//
//  Thin adapter over FluidAudio's ASR download API. The only file in the
//  project that imports FluidAudio — everything else talks to it through
//  this Swift-native interface so the SDK stays isolated.
//
//  ## Why we report ETA instead of a progress fraction
//
//  Earlier revisions tried to surface FluidAudio's `progress.fractionCompleted`
//  as a circular progress bar. That stream turned out to be unreliable for
//  display: under the pinned SDK (04747b3) the visible behavior was a quick
//  climb to ~5–10 % followed by an immediate snap to 100 %, leaving the
//  spinner running silently for the bulk of the actual download. The likely
//  root cause is that FluidAudio's internal `totalBytes` undercounts the
//  LFS-backed encoder weights file (`Encoder.mlmodelc/weights/weight.bin`,
//  ~445 MB on disk — confirmed via `du`), so `fractionCompleted` reaches its
//  capped 0.5 maximum well before the encoder finishes streaming.
//
//  Rather than chase that upstream bug, we ignore `fractionCompleted` for the
//  download phase entirely and observe the **filesystem** instead, which is
//  ground truth. Two locations are summed:
//
//    1. The model cache directory (files that FluidAudio has finished and
//       moved into place).
//    2. URLSession's in-flight `CFNetworkDownload_*.tmp` files inside the
//       sandbox tmp/caches dirs (the ~445 MB encoder weight is a single
//       URLSession request, so without watching the tmp file the cache dir
//       sits idle for several minutes mid-download).
//
//  A 2-second poll feeds samples into a small sliding window; speed is
//  derived from the oldest/newest pair, ETA from `(total - latest) / speed`.
//  FluidAudio's progress callback is still observed, but only to detect the
//  `.compiling` phase transition so we can flip to `.extracting` and stop the
//  poller.
//

import Foundation
import FluidAudio

struct FluidAudioDownloader {
    enum Failure: Error, LocalizedError {
        case unsupportedModel(String)
        case downloadIncomplete
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .unsupportedModel:
                return "Not available in this build."
            case .downloadIncomplete:
                return "Download incomplete, try again."
            case .underlying(let error):
                return error.localizedDescription
            }
        }
    }

    /// Maps catalog ids to FluidAudio model versions. Adding a new local
    /// model means adding a row here and a catalog entry in `ModelManager`.
    private static let versionsById: [String: AsrModelVersion] = [
        "parakeet-v2": .v2,
        "parakeet-v3": .v3
    ]

    /// Expected size of the raw HuggingFace download for each catalog id,
    /// used as the denominator when computing ETA. This is the **download**
    /// size (raw files before CoreML compilation), NOT the compiled on-disk
    /// size. Measured 2026-04-12 by observing `directorySize(at: cacheDir)`
    /// just before the `.compiling` phase:
    ///
    ///   parakeet-tdt-0.6b-v3:    ~493 MB raw download
    ///
    /// If the SDK pin starts pulling a different model set, refresh this
    /// table by checking the `[poll] dir=` debug logs during a clean
    /// download. Drift up to ~5 % is harmless — the formatter hides
    /// "≈ 0 ETA" as `<3s` and `estimateEta` clamps remaining ≥ 0.
    private static let totalBytesById: [String: Int64] = [
        "parakeet-v2": 500 * 1024 * 1024,
        "parakeet-v3": 500 * 1024 * 1024
    ]

    private func version(for id: String) throws -> AsrModelVersion {
        guard let v = Self.versionsById[id] else {
            throw Failure.unsupportedModel(id)
        }
        return v
    }
}

extension FluidAudioDownloader {
    func isInstalled(_ id: String) -> Bool {
        guard let v = try? version(for: id) else { return false }
        let dir = AsrModels.defaultCacheDirectory(for: v)
        return AsrModels.modelsExist(at: dir, version: v)
    }

    func cacheDirectory(_ id: String) -> URL? {
        guard let v = try? version(for: id) else { return nil }
        return AsrModels.defaultCacheDirectory(for: v)
    }
}

extension FluidAudioDownloader {
    /// Downloads the model identified by `id`, calling `onProgress` on the
    /// main actor with `.downloading(eta:)` updates as the disk poller
    /// accumulates samples, and `.extracting` once FluidAudio enters its
    /// CoreML compile phase. Throws `Failure.unsupportedModel` immediately
    /// for unknown ids, `CancellationError` if the surrounding Task is
    /// cancelled, and `Failure.downloadIncomplete` if files are missing
    /// after the call returns.
    func download(
        _ id: String,
        onProgress: @escaping @MainActor @Sendable (ModelEntry.Status) -> Void
    ) async throws {
        let v = try version(for: id)
        let cacheDir = AsrModels.defaultCacheDirectory(for: v)
        let totalBytes = Self.totalBytesById[id] ?? 0

        // Disk poller. Runs in parallel with `AsrModels.download` and is the
        // sole source of `.downloading(eta:)` updates. Cancelled either when
        // FluidAudio enters the compile phase (see progressHandler below) or
        // when the surrounding function exits via the `defer` below.
        //
        // Detached on purpose: a plain `Task` here inherits the main
        // actor, putting every 2 s recursive walk of a multi-GB model
        // tree (plus the whole shared tmp dir) on the main thread for
        // the duration of the download. Only the `onProgress` hops
        // touch main.
        let pollTask = Task.detached { [totalBytes, cacheDir] in
            // Snapshot CFNetworkDownload tmp files that exist BEFORE our
            // download starts. The app is not sandboxed, so NSTemporaryDirectory
            // is shared with other processes — without this baseline, we'd
            // count other apps' in-flight URLSession downloads as our own.
            let baselineTmpFiles = DownloadProgressUtils.cfNetworkDownloadFileURLs()

            // Sliding window of (timestamp, bytes) samples. ~6 samples × 2 s
            // = 12 s of history, which dampens momentary stalls (DNS, TLS,
            // server-side throttling) without making the ETA feel laggy.
            var samples: [(t: Date, bytes: Int64)] = [
                (t: Date(), bytes: Self.bytesDownloaded(cacheDir: cacheDir, excluding: baselineTmpFiles))
            ]
            // Emit one nil-ETA tick immediately so the UI flips to the
            // .downloading caption ("Preparing") right away, before the first
            // 2-second poll lands.
            await MainActor.run { onProgress(.downloading(fraction: nil, eta: nil)) }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }

                let bytes = Self.bytesDownloaded(cacheDir: cacheDir, excluding: baselineTmpFiles)
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
            _ = try await AsrModels.download(version: v, progressHandler: { progress in
                // Phase signal only — `progress.fractionCompleted` is not
                // trustworthy for display under the pinned SDK (see file
                // header). The disk poller is the sole source of byte
                // progress; here we just need to know when downloading
                // finishes so we can flip to .extracting and stop polling.
                guard case .compiling = progress.phase else { return }
                pollTask.cancel()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { onProgress(.extracting) }
                }
            })
        } catch is CancellationError {
            // Re-throw as-is so the caller sees CancellationError rather than
            // a Failure.underlying wrapper — ModelManager relies on this to
            // transition to .paused instead of .error.
            throw CancellationError()
        } catch {
            throw Failure.underlying(error)
        }

        guard AsrModels.modelsExist(at: cacheDir, version: v) else {
            throw Failure.downloadIncomplete
        }
    }

    /// Sum of bytes that count toward the download:
    ///   1. Files that FluidAudio has finished and moved into `cacheDir`.
    ///   2. URLSession's in-flight `CFNetworkDownload_*.tmp` files that
    ///      appeared AFTER our download started (excluding pre-existing
    ///      ones from other processes).
    // Nonisolated so the detached poll task can call it without
    // bouncing back to the main actor.
    nonisolated private static func bytesDownloaded(cacheDir: URL, excluding baselineFiles: Set<URL>) -> Int64 {
        DownloadProgressUtils.directorySize(at: cacheDir)
            + DownloadProgressUtils.inFlightDownloadBytes(excluding: baselineFiles)
    }
}
