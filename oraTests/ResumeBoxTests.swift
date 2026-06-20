//
//  ResumeBoxTests.swift
//  oraTests
//
//  Locks down the first-resume-wins contract of the gate that
//  arbitrates between engine-start completion and the 10-second
//  timeout. The return value is load-bearing since the timeout-leak
//  fix: a `false` from `tryResume(.success(engine))` tells the worker
//  thread it lost the race and must tear the engine down itself —
//  that's what keeps a late-started engine from holding the mic open
//  forever.
//

import AVFoundation
import Testing
@testable import ora

@MainActor
struct ResumeBoxTests {

    private struct TestError: Error {}

    @Test("success first: resumes with the engine; later failure is rejected")
    func successWins() async throws {
        let box = ResumeBox()
        let engine = AVAudioEngine()

        let resumed = try await withCheckedThrowingContinuation { cont in
            box.cont = cont
            #expect(box.tryResume(.success(engine)) == true)
            // The timeout fires later and must be told it lost.
            #expect(box.tryResume(.failure(TestError())) == false)
        }
        #expect(resumed === engine)
    }

    @Test("timeout first: resumes throwing; the late success is rejected so the worker tears down")
    func timeoutWins() async {
        let box = ResumeBox()
        let engine = AVAudioEngine()

        await #expect(throws: TestError.self) {
            try await withCheckedThrowingContinuation { cont in
                box.cont = cont
                #expect(box.tryResume(.failure(TestError())) == true)
                // Engine start completes after the timeout already won.
                // `false` here is the signal the production code uses
                // to stop the orphaned engine.
                #expect(box.tryResume(.success(engine)) == false)
            }
        }
    }

    @Test("every resume after the first is rejected, regardless of kind")
    func onlyFirstResumeWins() async throws {
        let box = ResumeBox()
        let engine = AVAudioEngine()

        _ = try await withCheckedThrowingContinuation { cont in
            box.cont = cont
            #expect(box.tryResume(.success(engine)) == true)
            #expect(box.tryResume(.success(engine)) == false)
            #expect(box.tryResume(.failure(TestError())) == false)
            #expect(box.tryResume(.failure(TestError())) == false)
        }
    }
}
