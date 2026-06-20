//
//  MLXModelConfig.swift
//  ora
//
//  Static mapping from catalog model IDs to HuggingFace repo IDs and
//  expected download sizes. The single source of truth for "which
//  HuggingFace repo does this catalog ID correspond to?" — used by
//  both MLXModelDownloader (for download/install checks) and
//  MLXTranscriber (for fromPretrained calls).
//

import Foundation

enum MLXModelConfig {
    struct Entry {
        let repoId: String
        /// Expected on-disk size in bytes after download. Used as the
        /// denominator for ETA estimation. Measured from a completed
        /// install; drift up to ~10% is harmless.
        let totalBytes: Int64
    }

    static let models: [String: Entry] = [
        "qwen3-asr-0.6b": Entry(
            repoId: "mlx-community/Qwen3-ASR-0.6B-8bit",
            totalBytes: 968 * 1024 * 1024
        ),
        "qwen3-asr-1.7b": Entry(
            repoId: "mlx-community/Qwen3-ASR-1.7B-8bit",
            totalBytes: 2468 * 1024 * 1024
        ),
    ]
}
