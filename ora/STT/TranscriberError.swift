//
//  TranscriberError.swift
//  ora
//
//  Shared error type for all local transcriber backends.
//  Replaces the identical Failure enums that were duplicated across
//  FluidAudioTranscriber, WhisperKitTranscriber, and MLXTranscriber.
//

import Foundation

enum TranscriberError: Error, LocalizedError {
    case modelNotDownloaded(name: String)
    case emptyAudio
    case loadFailed(Error)
    case inferenceFailed(Error)

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded(let name):
            return "The \(name) model isn't downloaded yet. Open Settings ▸ Models and download it before dictating."
        case .emptyAudio:
            return "The recording was empty — no audio frames to transcribe."
        case .loadFailed(let error):
            return "Failed to load the speech model: \(error.localizedDescription)"
        case .inferenceFailed(let error):
            return "Transcription failed: \(error.localizedDescription)"
        }
    }
}
