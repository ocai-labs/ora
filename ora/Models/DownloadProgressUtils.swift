//
//  DownloadProgressUtils.swift
//  ora
//
//  Pure filesystem utilities for download progress tracking. Extracted
//  from FluidAudioDownloader — these functions
//  have no SDK dependency and were duplicated verbatim.
//
//  Everything here is `nonisolated`: these helpers recursively walk
//  multi-GB model trees and the shared tmp directory, so they must be
//  callable from the downloaders' detached poll tasks — under the
//  target's MainActor default isolation they would otherwise hop back
//  to the main thread and stall the UI every poll tick.
//

import Foundation

enum DownloadProgressUtils {
    /// Recursively sums `totalFileAllocatedSize` for every regular file
    /// under `url`. Returns 0 if the directory doesn't exist yet.
    nonisolated static func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard
                let values = try? fileURL.resourceValues(
                    forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
                ),
                values.isRegularFile == true
            else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Returns the set of `CFNetworkDownload_*.tmp` file URLs currently
    /// present under the candidate tmp roots. Called once before a
    /// download starts to establish a baseline.
    nonisolated static func cfNetworkDownloadFileURLs() -> Set<URL> {
        var result = Set<URL>()
        for root in candidateTmpRoots() {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                if url.lastPathComponent.hasPrefix("CFNetworkDownload") {
                    result.insert(url)
                }
            }
        }
        return result
    }

    /// Sums sizes of CFNetworkDownload tmp files not in the baseline set.
    nonisolated static func inFlightDownloadBytes(excluding baselineFiles: Set<URL>) -> Int64 {
        var total: Int64 = 0
        for root in candidateTmpRoots() {
            total += scanCFNetworkDownloads(in: root, excluding: baselineFiles)
        }
        return total
    }

    /// Returns NSTemporaryDirectory + app-scoped caches subdirectory.
    nonisolated static func candidateTmpRoots() -> [URL] {
        var roots: [URL] = [URL(fileURLWithPath: NSTemporaryDirectory())]
        if let cachesDir = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first {
            let bundleID = Bundle.main.bundleIdentifier ?? "com.oceanai.ora"
            roots.append(cachesDir.appendingPathComponent(bundleID))
        }
        return roots
    }

    /// Sliding-window ETA from (timestamp, bytes) samples.
    nonisolated static func estimateEta(
        samples: [(t: Date, bytes: Int64)],
        totalBytes: Int64
    ) -> TimeInterval? {
        guard samples.count >= 2, totalBytes > 0 else { return nil }
        let first = samples.first!
        let last = samples.last!
        let bytesDelta = Double(last.bytes - first.bytes)
        let timeDelta = last.t.timeIntervalSince(first.t)
        guard timeDelta > 0, bytesDelta > 0 else { return nil }
        let speed = bytesDelta / timeDelta
        let remaining = max(0, Double(totalBytes - last.bytes))
        return remaining / speed
    }

    /// Sums CFNetworkDownload tmp files in a single directory,
    /// excluding baseline.
    nonisolated static func scanCFNetworkDownloads(
        in root: URL,
        excluding baselineFiles: Set<URL>
    ) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("CFNetworkDownload") else { continue }
            guard !baselineFiles.contains(url) else { continue }
            guard
                let values = try? url.resourceValues(
                    forKeys: [.fileSizeKey, .isRegularFileKey]
                ),
                values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
