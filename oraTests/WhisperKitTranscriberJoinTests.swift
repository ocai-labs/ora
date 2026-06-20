//
//  WhisperKitTranscriberJoinTests.swift
//  oraTests
//
//  Locks down the multi-chunk transcript joining added as insurance
//  against a future chunkingStrategy change: taking only
//  `results.first` would silently truncate long dictations to their
//  first ~30 s chunk.
//

import Testing
@testable import ora

@MainActor
struct WhisperKitTranscriberJoinTests {

    @Test("single chunk passes through trimmed")
    func singleChunk() {
        #expect(WhisperKitTranscriber.joinedTranscript([" hello world "]) == "hello world")
    }

    @Test("multiple chunks are joined in order (regression: only first chunk survived)")
    func multipleChunks() {
        #expect(
            WhisperKitTranscriber.joinedTranscript(["first chunk.", "second chunk.", "third."])
                == "first chunk. second chunk. third."
        )
    }

    @Test("empty and whitespace-only chunks don't produce stray spaces")
    func emptyChunksSkipped() {
        #expect(WhisperKitTranscriber.joinedTranscript(["a", "", "  ", "b"]) == "a b")
    }

    @Test("no chunks yields the empty string")
    func noChunks() {
        #expect(WhisperKitTranscriber.joinedTranscript([]) == "")
    }
}
