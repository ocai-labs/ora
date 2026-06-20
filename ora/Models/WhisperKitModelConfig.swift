//
//  WhisperKitModelConfig.swift
//  ora
//
//  Static mapping from catalog model IDs to WhisperKit variant names
//  and expected download sizes. The single source of truth for "which
//  WhisperKit model does this catalog ID correspond to?" — used by both
//  WhisperKitModelDownloader (for download/install checks) and
//  WhisperKitTranscriber (for pipeline init).
//

import Foundation

enum WhisperKitModelConfig {
    struct Entry {
        /// The variant name passed to `WhisperKit.download(variant:)` and
        /// used as the subdirectory name under the WhisperKit cache.
        let variant: String
        /// Expected on-disk size in bytes after download. Used as the
        /// denominator for ETA estimation. Measured from a completed
        /// install; drift up to ~10% is harmless.
        let totalBytes: Int64
    }

    /// HuggingFace repo hosting pre-converted CoreML models.
    static let repo = "argmaxinc/whisperkit-coreml"

    static let models: [String: Entry] = [
        "whisper-large-v3-turbo": Entry(
            variant: "openai_whisper-large-v3_turbo",
            totalBytes: 3000 * 1024 * 1024
        ),
        "whisper-distil-large-v3": Entry(
            variant: "distil-whisper_distil-large-v3",
            totalBytes: 1400 * 1024 * 1024
        ),
        "whisper-small": Entry(
            variant: "openai_whisper-small",
            totalBytes: 479 * 1024 * 1024
        ),
        "whisper-tiny": Entry(
            variant: "openai_whisper-tiny",
            totalBytes: 73 * 1024 * 1024
        ),
    ]
}
