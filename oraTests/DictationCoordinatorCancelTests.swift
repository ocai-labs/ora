//
//  DictationCoordinatorCancelTests.swift
//  oraTests
//
//  Locks down the pure decision function that tells cancel() whether
//  to act on the current state. Following the same narrow-pure-fn
//  pattern as DictationCoordinatorErrorMappingTests.
//

import Testing
@testable import ora

@MainActor
struct DictationCoordinatorCancelTests {

    @Test("cancel from .starting → .act")
    func cancelFromStarting() {
        // .starting is the boot window between press and engine-ready.
        // ESC must work there too — that's the whole point of moving
        // engine.prepare() off the main thread.
        #expect(DictationCoordinator.handleCancel(from: .starting) == .act)
    }

    @Test("cancel from .recording → .act")
    func cancelFromRecording() {
        #expect(DictationCoordinator.handleCancel(from: .recording) == .act)
    }

    @Test("cancel from .transcribing → .act")
    func cancelFromTranscribing() {
        #expect(DictationCoordinator.handleCancel(from: .transcribing) == .act)
    }

    @Test("cancel from .idle → .ignore")
    func cancelFromIdle() {
        #expect(DictationCoordinator.handleCancel(from: .idle) == .ignore)
    }

    // `.error` is matched as a whole family in `handleCancel` — `ErrorKind` is
    // not inspected. Two representative sub-cases (a plain case and an
    // associated-value case) are sufficient; the compiler's exhaustiveness
    // check covers the rest.

    @Test("cancel from .error(.noMic) → .ignore")
    func cancelFromErrorNoMic() {
        #expect(DictationCoordinator.handleCancel(from: .error(.noMic)) == .ignore)
    }

    @Test("cancel from .error(.generic) → .ignore")
    func cancelFromErrorGeneric() {
        #expect(DictationCoordinator.handleCancel(from: .error(.generic("x"))) == .ignore)
    }
}
