//
//  TranscriberErrorTests.swift
//  oraTests
//
//  Locks down the errorDescription contract for TranscriberError,
//  the shared error enum used by all local transcribers.
//

import Foundation
import Testing
@testable import ora

struct TranscriberErrorTests {

    // MARK: - modelNotDownloaded (model-name parameterised)

    @Test("modelNotDownloaded mentions the model name")
    func modelNotDownloadedIncludesName() {
        let desc = TranscriberError.modelNotDownloaded(name: "Parakeet").errorDescription!
        #expect(desc.contains("Parakeet"))
        #expect(desc.contains("Settings"))
        #expect(desc.contains("Models"))
    }

    @Test("modelNotDownloaded works for each backend name")
    func modelNotDownloadedVariants() {
        for name in ["Parakeet", "Whisper", "Qwen3-ASR"] {
            let desc = TranscriberError.modelNotDownloaded(name: name).errorDescription!
            #expect(desc.contains(name))
        }
    }

    // MARK: - Shared cases

    @Test("emptyAudio has expected description")
    func emptyAudio() {
        let desc = TranscriberError.emptyAudio.errorDescription!
        #expect(desc == "The recording was empty — no audio frames to transcribe.")
    }

    @Test("loadFailed includes the inner error's localized description")
    func loadFailed() {
        let inner = NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "disk full"
        ])
        let desc = TranscriberError.loadFailed(inner).errorDescription!
        #expect(desc == "Failed to load the speech model: disk full")
    }

    @Test("inferenceFailed includes the inner error's localized description")
    func inferenceFailed() {
        let inner = NSError(domain: "test", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "tensor shape mismatch"
        ])
        let desc = TranscriberError.inferenceFailed(inner).errorDescription!
        #expect(desc == "Transcription failed: tensor shape mismatch")
    }

    // MARK: - All cases produce non-nil descriptions

    @Test("all cases have non-nil errorDescription")
    func allCasesHaveDescriptions() {
        let inner = NSError(domain: "t", code: 0)
        let cases: [TranscriberError] = [
            .modelNotDownloaded(name: "Test"),
            .emptyAudio,
            .loadFailed(inner),
            .inferenceFailed(inner),
        ]
        for c in cases {
            #expect(c.errorDescription != nil)
        }
    }
}
