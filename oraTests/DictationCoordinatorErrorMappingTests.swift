//
//  DictationCoordinatorErrorMappingTests.swift
//  oraTests
//
//  Locks down the contract of DictationCoordinator.stateForPipelineError —
//  the pure function that maps transcriber/paster errors to coordinator
//  states. Every error type that can emerge from the transcribe+paste
//  pipeline is covered so the TranscriberError unification can be
//  validated against these expectations.
//

import Foundation
import Testing
@testable import ora

@MainActor
struct DictationCoordinatorErrorMappingTests {

    // MARK: - TranscriberError

    @Test("TranscriberError modelNotDownloaded → error(.noModel)")
    func transcriberModelNotDownloaded() {
        let state = DictationCoordinator.stateForPipelineError(
            TranscriberError.modelNotDownloaded(name: "TestModel")
        )
        #expect(state == .error(.noModel))
    }

    @Test("TranscriberError emptyAudio → idle")
    func transcriberEmptyAudio() {
        let state = DictationCoordinator.stateForPipelineError(
            TranscriberError.emptyAudio
        )
        #expect(state == .idle)
    }

    @Test("TranscriberError inferenceFailed → error pill (regression: was silent idle)")
    func transcriberInferenceFailed() {
        let state = DictationCoordinator.stateForPipelineError(
            TranscriberError.inferenceFailed(StubError.sample)
        )
        #expect(state == .error(.generic("Transcription failed")))
        #expect(DictationCoordinator.transcriptionFailedMessage.count <= 32)
    }

    @Test("TranscriberError loadFailed → error(.generic(...))")
    func transcriberLoadFailed() {
        let state = DictationCoordinator.stateForPipelineError(
            TranscriberError.loadFailed(StubError.sample)
        )
        guard case .error(.generic(let msg)) = state else {
            Issue.record("Expected .error(.generic), got \(state)")
            return
        }
        #expect(msg.count <= 32)
    }

    // MARK: - APITranscriber.Failure

    @Test("API missingAPIKey → error(.generic('Configure API in Settings'))")
    func apiMissingAPIKey() {
        let state = DictationCoordinator.stateForPipelineError(
            APITranscriber.Failure.missingAPIKey
        )
        #expect(state == .error(.generic("Configure API in Settings")))
    }

    @Test("API missingModel → error(.generic('Configure API in Settings'))")
    func apiMissingModel() {
        let state = DictationCoordinator.stateForPipelineError(
            APITranscriber.Failure.missingModel
        )
        #expect(state == .error(.generic("Configure API in Settings")))
    }

    @Test("API emptyAudio → idle")
    func apiEmptyAudio() {
        let state = DictationCoordinator.stateForPipelineError(
            APITranscriber.Failure.emptyAudio
        )
        #expect(state == .idle)
    }

    @Test("API network → error(.generic(...))")
    func apiNetwork() {
        let state = DictationCoordinator.stateForPipelineError(
            APITranscriber.Failure.network(StubError.sample)
        )
        guard case .error(.generic) = state else {
            Issue.record("Expected .error(.generic), got \(state)")
            return
        }
    }

    @Test("API httpStatus → error(.generic(...))")
    func apiHttpStatus() {
        let state = DictationCoordinator.stateForPipelineError(
            APITranscriber.Failure.httpStatus(500, "Internal Server Error")
        )
        guard case .error(.generic) = state else {
            Issue.record("Expected .error(.generic), got \(state)")
            return
        }
    }

    @Test("API decodingFailed → error(.generic(...))")
    func apiDecodingFailed() {
        let state = DictationCoordinator.stateForPipelineError(
            APITranscriber.Failure.decodingFailed
        )
        guard case .error(.generic) = state else {
            Issue.record("Expected .error(.generic), got \(state)")
            return
        }
    }

    @Test("API encodingFailed → error(.generic(...))")
    func apiEncodingFailed() {
        let state = DictationCoordinator.stateForPipelineError(
            APITranscriber.Failure.encodingFailed(StubError.sample)
        )
        guard case .error(.generic) = state else {
            Issue.record("Expected .error(.generic), got \(state)")
            return
        }
    }

    // MARK: - Paster.Failure

    @Test("Paster accessibilityNotTrusted → error(.noAccessibility)")
    func pasterAccessibilityNotTrusted() {
        let state = DictationCoordinator.stateForPipelineError(
            Paster.Failure.accessibilityNotTrusted
        )
        #expect(state == .error(.noAccessibility))
    }

    @Test("Paster eventCreationFailed → error(.generic(...))")
    func pasterEventCreationFailed() {
        let state = DictationCoordinator.stateForPipelineError(
            Paster.Failure.eventCreationFailed
        )
        guard case .error(.generic) = state else {
            Issue.record("Expected .error(.generic), got \(state)")
            return
        }
    }

    // MARK: - Unknown / fallback

    @Test("Unknown error → error(.generic(...)) with truncated message")
    func unknownError() {
        let state = DictationCoordinator.stateForPipelineError(StubError.sample)
        guard case .error(.generic(let msg)) = state else {
            Issue.record("Expected .error(.generic), got \(state)")
            return
        }
        #expect(msg.count <= 32)
    }

    @Test("Long error description is truncated to 32 characters")
    func longErrorDescriptionTruncated() {
        let state = DictationCoordinator.stateForPipelineError(StubError.longMessage)
        guard case .error(.generic(let msg)) = state else {
            Issue.record("Expected .error(.generic), got \(state)")
            return
        }
        #expect(msg.count == 32)
    }
}

// MARK: - Test helpers

private enum StubError: Error, LocalizedError {
    case sample
    case longMessage

    var errorDescription: String? {
        switch self {
        case .sample:
            return "stub error"
        case .longMessage:
            return "This is a very long error message that should be truncated by shortMessage"
        }
    }
}
