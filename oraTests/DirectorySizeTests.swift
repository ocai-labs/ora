//
//  DirectorySizeTests.swift
//  oraTests
//
//  Verifies the recursive directory size calculation used by
//  FluidAudioDownloader and MLXModelDownloader for download progress.
//  This function is being extracted to DownloadProgressUtils — these
//  tests verify the contract is preserved after the move.
//

import Foundation
import Testing
@testable import ora

@MainActor
struct DirectorySizeTests {

    // MARK: - Helpers

    /// Creates a temporary directory and returns its URL.
    /// The caller is responsible for cleanup via `defer`.
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ora-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes `byteCount` bytes of zeros to a file at `url`.
    private func writeFile(at url: URL, byteCount: Int) throws {
        let data = Data(count: byteCount)
        try data.write(to: url)
    }

    // MARK: - Tests

    @Test("empty directory returns 0")
    func emptyDirectory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let size = DownloadProgressUtils.directorySize(at: dir)
        #expect(size == 0)
    }

    @Test("nonexistent directory returns 0")
    func nonexistentDirectory() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ora-nonexistent-\(UUID().uuidString)")
        let size = DownloadProgressUtils.directorySize(at: dir)
        #expect(size == 0)
    }

    @Test("single file returns its allocated size")
    func singleFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeFile(at: dir.appendingPathComponent("model.bin"), byteCount: 4096)

        let size = DownloadProgressUtils.directorySize(at: dir)
        // totalFileAllocatedSize may round up to block boundaries,
        // so we check it's at least the written bytes and positive.
        #expect(size >= 4096)
    }

    @Test("multiple files sums their sizes")
    func multipleFiles() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeFile(at: dir.appendingPathComponent("a.bin"), byteCount: 4096)
        try writeFile(at: dir.appendingPathComponent("b.bin"), byteCount: 8192)

        let size = DownloadProgressUtils.directorySize(at: dir)
        #expect(size >= 4096 + 8192)
    }

    @Test("nested subdirectories are included recursively")
    func nestedSubdirectories() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sub = dir.appendingPathComponent("sub/deep", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try writeFile(at: dir.appendingPathComponent("top.bin"), byteCount: 1024)
        try writeFile(at: sub.appendingPathComponent("nested.bin"), byteCount: 2048)

        let size = DownloadProgressUtils.directorySize(at: dir)
        #expect(size >= 1024 + 2048)
    }

    @Test("hidden files are skipped")
    func hiddenFilesSkipped() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeFile(at: dir.appendingPathComponent("visible.bin"), byteCount: 4096)
        try writeFile(at: dir.appendingPathComponent(".hidden"), byteCount: 4096)

        let sizeWithHidden = DownloadProgressUtils.directorySize(at: dir)
        // Should only count visible.bin. The allocated size should be
        // roughly one file's worth, not two.
        // We verify hidden is skipped by checking size < 2 * visible allocated size.
        // Since allocated size >= logical size, a single 4096-byte file
        // produces at most one block (typically 4096 or 8192).
        let oneDirSize = DownloadProgressUtils.directorySize(
            at: { () -> URL in
                let d = try! makeTempDir()
                try! writeFile(at: d.appendingPathComponent("only.bin"), byteCount: 4096)
                return d
            }()
        )
        // If hidden files were counted, size would be ~2x oneDirSize
        #expect(sizeWithHidden <= oneDirSize + 1024) // allow small variance
    }
}
