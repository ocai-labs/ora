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
    /// Parakeet-family model means adding a row here and a catalog entry
    /// in `ModelManager`. (Nemotron Unified is not an `AsrModelVersion`;
    /// it has its own path below.)
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

    // MARK: Nemotron Unified

    /// Nemotron Unified isn't an `AsrModelVersion` (it's FluidAudio's
    /// separate Unified/RNNT backend), so it gets its own small path:
    /// `ModelHub` for the download, and a file check of our own for
    /// "installed". See NemotronUnifiedTranscriber for why fp16.
    static let nemotronUnifiedPrecision: UnifiedEncoderPrecision = .fp16

    /// Raw download for the offline fp16 set, from the HF tree listing
    /// (2026-11-11): encoder 1196.6 MB + decoder 18.4 MB + joint 7.4 MB
    /// + vocab/metadata ≈ 1222 MB.
    private static let nemotronUnifiedTotalBytes: Int64 = 1222 * 1000 * 1000

    /// ~/Library/Application Support/FluidAudio/Models — the same base
    /// `UnifiedAsrManager.loadModels()` uses, so a model fetched by any
    /// FluidAudio-based tool is found here too.
    static var fluidAudioModelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    static var nemotronUnifiedCacheDirectory: URL {
        fluidAudioModelsDirectory.appendingPathComponent(Repo.nemotronUnified.folderName, isDirectory: true)
    }

    /// The files `UnifiedAsrManager.loadModels(from:)` opens for the
    /// offline path.
    private static var nemotronUnifiedRequiredFiles: [String] {
        let family = UnifiedModelFamily.nemotronMultilingual(.auto)
        return [
            family.offlineEncoderFile(precision: nemotronUnifiedPrecision),
            family.decoderFile,
            family.jointDecisionFile,
            family.vocab,
        ]
    }

    /// Complete = every required file is present and, for each compiled
    /// bundle, load-ready (see `bundleIsComplete`). Mirrors FluidAudio's
    /// own `ModelCache.incompleteFiles`, which is internal to the SDK.
    /// Bare directory existence — or even a root `coremldata.bin` —
    /// isn't enough: FluidAudio downloads a bundle file by file, so an
    /// interrupted 1.2 GB fetch can leave `coremldata.bin` in place
    /// with the program or weights still missing, and the card would
    /// then claim "Downloaded" for a model that can't load.
    private static func nemotronUnifiedFilesComplete() -> Bool {
        let dir = nemotronUnifiedCacheDirectory
        return nemotronUnifiedRequiredFiles.allSatisfy { name in
            let url = dir.appendingPathComponent(name)
            return name.hasSuffix(".mlmodelc")
                ? bundleIsComplete(url)
                : FileManager.default.fileExists(atPath: url.path)
        }
    }

    /// A compiled ML-program bundle is load-ready when it has its root
    /// `coremldata.bin`, a `model.mil` that ends with the brace closing
    /// the program (a truncated one segfaults Core ML), every
    /// `@model_path/…` file the program references (the weights) present
    /// and non-empty, and no `*.partial` staging file left inside it.
    /// Only the bundle itself is scanned for `.partial`, so stray files
    /// elsewhere in the shared FluidAudio cache can't wedge the model.
    private static func bundleIsComplete(_ bundle: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: bundle.appendingPathComponent("coremldata.bin").path),
              let mil = fm.contents(atPath: bundle.appendingPathComponent("model.mil").path)
        else { return false }

        let whitespace: Set<UInt8> = [0x09, 0x0A, 0x0D, 0x20]
        guard let last = mil.lastIndex(where: { !whitespace.contains($0) }),
              mil[last] == UInt8(ascii: "}")
        else { return false }

        let marker = Data("@model_path/".utf8)
        var searchStart = mil.startIndex
        while let match = mil.range(of: marker, in: searchStart..<mil.endIndex) {
            guard let end = mil[match.upperBound...].firstIndex(of: UInt8(ascii: "\"")) else { break }
            if let reference = String(data: mil[match.upperBound..<end], encoding: .utf8), !reference.isEmpty {
                let path = bundle.appendingPathComponent(reference).path
                let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
                guard size > 0 else { return false }
            }
            searchStart = end
        }

        if let walker = fm.enumerator(at: bundle, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension == "partial" {
                return false
            }
        }
        return true
    }
}

extension FluidAudioDownloader {
    func isInstalled(_ id: String) -> Bool {
        if id == NemotronUnifiedTranscriber.modelId { return Self.nemotronUnifiedFilesComplete() }
        guard let v = try? version(for: id) else { return false }
        let dir = AsrModels.defaultCacheDirectory(for: v)
        return AsrModels.modelsExist(at: dir, version: v)
    }

    func cacheDirectory(_ id: String) -> URL? {
        if id == NemotronUnifiedTranscriber.modelId { return Self.nemotronUnifiedCacheDirectory }
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
        let isNemotron = id == NemotronUnifiedTranscriber.modelId
        let v: AsrModelVersion? = isNemotron ? nil : try version(for: id)
        let cacheDir = v.map { AsrModels.defaultCacheDirectory(for: $0) } ?? Self.nemotronUnifiedCacheDirectory
        let totalBytes = isNemotron ? Self.nemotronUnifiedTotalBytes : (Self.totalBytesById[id] ?? 0)

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

        // Phase signal only — `progress.fractionCompleted` is not
        // trustworthy for display under the pinned SDK (see file
        // header). The disk poller is the sole source of byte
        // progress; here we just need to know when downloading
        // finishes so we can flip to .extracting and stop polling.
        let progressHandler: ProgressHandler = { progress in
            guard case .compiling = progress.phase else { return }
            pollTask.cancel()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { onProgress(.extracting) }
            }
        }

        do {
            if let v {
                _ = try await AsrModels.download(version: v, progressHandler: progressHandler)
            } else {
                // The Nemotron repo ships pre-compiled .mlmodelc bundles,
                // so there's normally no compile phase: the poller simply
                // runs until the download returns. "offline-fp16" limits
                // the fetch to the batch encoder + decoder + joint + vocab
                // (the repo also holds ~10 GB of streaming / int8 /
                // .mlpackage variants we don't want).
                try await ModelHub.download(
                    .nemotronUnified,
                    to: Self.fluidAudioModelsDirectory,
                    variant: "offline-fp16",
                    progressHandler: progressHandler)
            }
        } catch {
            // Any cancellation — our CancellationError, or the URLError
            // .cancelled / NSUserCancelledError FluidAudio's downloader
            // surfaces when the Pause button cancels the URLSession task
            // mid-transfer — re-throws as CancellationError so
            // ModelManager shows .paused instead of an error.
            if Task.isCancelled || Self.isCancellation(error) {
                throw CancellationError()
            }
            throw Failure.underlying(error)
        }

        let complete = v.map { AsrModels.modelsExist(at: cacheDir, version: $0) }
            ?? Self.nemotronUnifiedFilesComplete()
        guard complete else {
            throw Failure.downloadIncomplete
        }
    }

    /// Same rule as FluidAudio's (internal) `RetryPolicy.isCancellation`:
    /// walk the NSError chain looking for a URL or user cancellation.
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        var current: NSError? = error as NSError
        var visited: Set<ObjectIdentifier> = []
        while let nsError = current, visited.insert(ObjectIdentifier(nsError)).inserted {
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return true }
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError { return true }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
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
