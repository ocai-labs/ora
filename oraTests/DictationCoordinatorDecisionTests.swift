//
//  DictationCoordinatorDecisionTests.swift
//  oraTests
//
//  Locks down the three pure decision tables added in the
//  cancel/re-press race-fix pass: what a hotkey press does, what a
//  release does, and how the engine-boot Task resolves once
//  `recorder.start` returns. Same narrow-pure-fn pattern as
//  DictationCoordinatorCancelTests.
//
//  The rows worth reading twice are the regression cases:
//   - toggle press during .starting must request a deferred stop
//     (it used to be silently dropped, leaving the recording running)
//   - a stale boot (generation mismatch) must release the engine only
//     when nothing newer owns the recorder
//   - the stop tail must not proceed from .idle (a cancel got there
//     first; proceeding used to resurrect a cancelled dictation)
//

import CoreGraphics
import Testing
@testable import ora

@MainActor
struct DictationCoordinatorDecisionTests {

    // MARK: - pressAction

    @Test("press from idle starts a dictation in both modes")
    func pressFromIdle() {
        #expect(DictationCoordinator.pressAction(from: .idle, mode: .hold) == .startDictation)
        #expect(DictationCoordinator.pressAction(from: .idle, mode: .toggle) == .startDictation)
    }

    @Test("press from error re-runs preflight in both modes")
    func pressFromError() {
        #expect(DictationCoordinator.pressAction(from: .error(.noMic), mode: .hold) == .startDictation)
        #expect(DictationCoordinator.pressAction(from: .error(.noModel), mode: .toggle) == .startDictation)
    }

    @Test("toggle press during .starting requests a deferred stop (regression: was dropped)")
    func togglePressDuringStarting() {
        #expect(
            DictationCoordinator.pressAction(from: .starting, mode: .toggle)
                == .requestStopAfterBoot
        )
    }

    @Test("hold press during .starting is noise")
    func holdPressDuringStarting() {
        #expect(DictationCoordinator.pressAction(from: .starting, mode: .hold) == .ignore)
    }

    @Test("toggle press while recording stops and transcribes")
    func togglePressWhileRecording() {
        #expect(
            DictationCoordinator.pressAction(from: .recording, mode: .toggle)
                == .stopAndTranscribe
        )
    }

    @Test("hold press while recording is noise")
    func holdPressWhileRecording() {
        #expect(DictationCoordinator.pressAction(from: .recording, mode: .hold) == .ignore)
    }

    @Test("press while transcribing is noise in both modes")
    func pressWhileTranscribing() {
        #expect(DictationCoordinator.pressAction(from: .transcribing, mode: .hold) == .ignore)
        #expect(DictationCoordinator.pressAction(from: .transcribing, mode: .toggle) == .ignore)
    }

    // MARK: - releaseAction

    @Test("hold release while recording stops and transcribes")
    func holdReleaseWhileRecording() {
        #expect(
            DictationCoordinator.releaseAction(from: .recording, mode: .hold)
                == .stopAndTranscribe
        )
    }

    @Test("hold release during .starting defers the stop until boot resolves")
    func holdReleaseDuringStarting() {
        #expect(
            DictationCoordinator.releaseAction(from: .starting, mode: .hold)
                == .requestStopAfterBoot
        )
    }

    @Test("toggle release is never a signal")
    func toggleReleaseIgnored() {
        #expect(DictationCoordinator.releaseAction(from: .recording, mode: .toggle) == .ignore)
        #expect(DictationCoordinator.releaseAction(from: .starting, mode: .toggle) == .ignore)
    }

    @Test("release with no matching start is noise")
    func releaseWithoutStart() {
        #expect(DictationCoordinator.releaseAction(from: .idle, mode: .hold) == .ignore)
        #expect(DictationCoordinator.releaseAction(from: .transcribing, mode: .hold) == .ignore)
        #expect(DictationCoordinator.releaseAction(from: .error(.noMic), mode: .hold) == .ignore)
    }

    // MARK: - bootResolution (current generation)

    @Test("current boot, still .starting, no stop request → begin recording")
    func currentBootBeginsRecording() {
        #expect(
            DictationCoordinator.bootResolution(
                generationMatches: true, state: .starting, stopRequested: false
            ) == .beginRecording
        )
    }

    @Test("current boot with a mid-boot stop request → run the stop tail")
    func currentBootRunsStopTail() {
        #expect(
            DictationCoordinator.bootResolution(
                generationMatches: true, state: .starting, stopRequested: true
            ) == .runStopTail
        )
    }

    @Test("current boot observing a non-.starting state releases the engine (defensive)")
    func currentBootDefensiveRelease() {
        for state: DictationCoordinator.State in [.idle, .recording, .transcribing, .error(.noMic)] {
            #expect(
                DictationCoordinator.bootResolution(
                    generationMatches: true, state: state, stopRequested: false
                ) == .releaseEngine
            )
        }
    }

    // MARK: - bootResolution (stale generation: cancel happened mid-boot)

    @Test("stale boot with nothing newer running releases the engine")
    func staleBootReleasesEngine() {
        #expect(
            DictationCoordinator.bootResolution(
                generationMatches: false, state: .idle, stopRequested: false
            ) == .releaseEngine
        )
        #expect(
            DictationCoordinator.bootResolution(
                generationMatches: false, state: .error(.noMic), stopRequested: false
            ) == .releaseEngine
        )
    }

    @Test("stale boot must not touch a newer attempt's recorder (regression: cancel + quick re-press)")
    func staleBootLeavesNewerAttemptAlone() {
        // A newer press adopted the running engine session; releasing
        // it here would kill the user's live recording.
        for state: DictationCoordinator.State in [.starting, .recording, .transcribing] {
            #expect(
                DictationCoordinator.bootResolution(
                    generationMatches: false, state: state, stopRequested: false
                ) == .ignore
            )
        }
    }

    @Test("a stale boot's stop request belongs to the dead attempt and is not honored")
    func staleBootIgnoresStopRequest() {
        #expect(
            DictationCoordinator.bootResolution(
                generationMatches: false, state: .starting, stopRequested: true
            ) == .ignore
        )
    }

    // MARK: - stopTailMayProceed

    @Test("stop tail proceeds only from .recording / .starting (regression: cancel race resurrected the pipeline)")
    func stopTailGuard() {
        #expect(DictationCoordinator.stopTailMayProceed(from: .recording))
        #expect(DictationCoordinator.stopTailMayProceed(from: .starting))
        #expect(!DictationCoordinator.stopTailMayProceed(from: .idle))
        #expect(!DictationCoordinator.stopTailMayProceed(from: .transcribing))
        #expect(!DictationCoordinator.stopTailMayProceed(from: .error(.noMic)))
    }

    // MARK: - stopTailAlreadyClaimed (duplicate stop triggers)

    @Test("first stop trigger of a dictation claims the tail")
    func firstStopClaims() {
        #expect(!DictationCoordinator.stopTailAlreadyClaimed(claimedGeneration: nil, currentGeneration: 3))
        // A claim left over from an earlier dictation (cancel / new
        // press bumped the generation) doesn't block this one.
        #expect(!DictationCoordinator.stopTailAlreadyClaimed(claimedGeneration: 2, currentGeneration: 3))
    }

    @Test("Return then hold release: the release is a duplicate stop (regression: second tail dropped the recording)")
    func returnThenReleaseIsDuplicate() {
        // Both triggers see .recording while the first tail awaits the
        // engine teardown, so both decision tables say stop…
        #expect(DictationCoordinator.returnAction(from: .recording) == .stopAndTranscribe)
        #expect(DictationCoordinator.releaseAction(from: .recording, mode: .hold) == .stopAndTranscribe)
        // …and the claim made by the Return turns the release into a no-op.
        #expect(DictationCoordinator.stopTailAlreadyClaimed(claimedGeneration: 5, currentGeneration: 5))
    }

    @Test("double Return / Return then toggle press: second trigger is a duplicate")
    func doubleStopIsDuplicate() {
        #expect(DictationCoordinator.returnAction(from: .recording) == .stopAndTranscribe)
        #expect(DictationCoordinator.pressAction(from: .recording, mode: .toggle) == .stopAndTranscribe)
        #expect(DictationCoordinator.stopTailAlreadyClaimed(claimedGeneration: 1, currentGeneration: 1))
    }

    // MARK: - returnAction (Return / keypad Enter finishes a dictation)

    @Test("Return while recording stops and transcribes")
    func returnWhileRecording() {
        #expect(DictationCoordinator.returnAction(from: .recording) == .stopAndTranscribe)
    }

    @Test("Return during .starting requests a deferred stop, like a toggle re-press")
    func returnDuringStarting() {
        #expect(DictationCoordinator.returnAction(from: .starting) == .requestStopAfterBoot)
    }

    @Test("Return is ignored when no recording is active")
    func returnIgnoredOtherwise() {
        #expect(DictationCoordinator.returnAction(from: .idle) == .ignore)
        #expect(DictationCoordinator.returnAction(from: .transcribing) == .ignore)
        #expect(DictationCoordinator.returnAction(from: .error(.noMic)) == .ignore)
    }

    @Test("Return is armed (consumed) exactly when it finishes the dictation")
    func returnArmingMatchesAction() {
        let states: [DictationCoordinator.State] = [
            .idle, .starting, .recording, .transcribing, .error(.generic("x")),
        ]
        for state in states {
            #expect(
                DictationCoordinator.returnIsArmed(in: state)
                    == (DictationCoordinator.returnAction(from: state) != .ignore)
            )
        }
        #expect(DictationCoordinator.returnIsArmed(in: .recording))
        #expect(!DictationCoordinator.returnIsArmed(in: .transcribing))
    }

    @Test("hold mode allows the activation key's modifier with Return; toggle allows none")
    func allowedReturnModifiers() {
        #expect(DictationCoordinator.allowedReturnModifiers(mode: .hold, key: .rightCommand) == .maskCommand)
        #expect(DictationCoordinator.allowedReturnModifiers(mode: .hold, key: .fn) == .maskSecondaryFn)
        #expect(DictationCoordinator.allowedReturnModifiers(mode: .toggle, key: .rightCommand) == [])
    }
}
