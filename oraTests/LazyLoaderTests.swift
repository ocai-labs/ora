//
//  LazyLoaderTests.swift
//  oraTests
//
//  Locks down the documented LazyLoader contract: load-once caching,
//  coalescing of concurrent callers, and failure-clears-task-so-retry-
//  works. Also carries the (disabled) desired-behavior test for review
//  finding #5 — a hung load currently wedges every future dictation
//  with no recovery short of relaunching.
//

import Testing
@testable import ora

@MainActor
struct LazyLoaderTests {

    private struct LoadError: Error {}
    private struct Unavailable: Error {}

    @Test("loads once and caches the value")
    func loadsOnceAndCaches() async throws {
        let loader = LazyLoader<Int>()
        var loadCount = 0

        for _ in 0..<3 {
            let value = try await loader.get(
                isAvailable: { true },
                unavailableError: Unavailable(),
                load: {
                    loadCount += 1
                    return 42
                }
            )
            #expect(value == 42)
        }
        #expect(loadCount == 1)
    }

    @Test("throws unavailableError without attempting a load")
    func unavailableThrows() async {
        let loader = LazyLoader<Int>()
        var loadCount = 0

        await #expect(throws: Unavailable.self) {
            _ = try await loader.get(
                isAvailable: { false },
                unavailableError: Unavailable(),
                load: {
                    loadCount += 1
                    return 1
                }
            )
        }
        #expect(loadCount == 0)
    }

    @Test("a failed load clears the task so the next call retries")
    func failureAllowsRetry() async throws {
        let loader = LazyLoader<Int>()
        var attempts = 0

        await #expect(throws: LoadError.self) {
            _ = try await loader.get(
                isAvailable: { true },
                unavailableError: Unavailable(),
                load: {
                    attempts += 1
                    throw LoadError()
                }
            )
        }

        let value = try await loader.get(
            isAvailable: { true },
            unavailableError: Unavailable(),
            load: {
                attempts += 1
                return 7
            }
        )
        #expect(value == 7)
        #expect(attempts == 2)
    }

    @Test("concurrent callers share a single in-flight load")
    func coalescesConcurrentCallers() async throws {
        let loader = LazyLoader<Int>()
        let gate = Gate()
        var loadCount = 0

        let first = Task { @MainActor in
            try await loader.get(
                isAvailable: { true },
                unavailableError: Unavailable(),
                load: {
                    loadCount += 1
                    await gate.wait()
                    return 9
                }
            )
        }
        // Let the first caller reach the suspended load before the
        // second arrives, bounded so a regression can't hang the suite.
        for _ in 0..<1_000 where !gate.hasWaiter { await Task.yield() }
        #expect(gate.hasWaiter)

        let second = Task { @MainActor in
            try await loader.get(
                isAvailable: { true },
                unavailableError: Unavailable(),
                load: {
                    loadCount += 1
                    return -1  // must never run
                }
            )
        }
        // Give the second caller a chance to attach to the in-flight task.
        for _ in 0..<10 { await Task.yield() }

        gate.open()
        let firstValue = try await first.value
        let secondValue = try await second.value
        #expect(firstValue == 9)
        #expect(secondValue == 9)
        #expect(loadCount == 1)
    }

    @Test("a hung load times out instead of wedging every future dictation")
    func hungLoadTimesOut() async throws {
        let loader = LazyLoader<Int>(loadTimeout: .milliseconds(50))
        await #expect(throws: ModelLoadTimedOut.self) {
            _ = try await loader.get(
                isAvailable: { true },
                unavailableError: Unavailable(),
                load: {
                    // Simulates a wedged CoreML compile.
                    try? await Task.sleep(for: .seconds(3600))
                    return 0
                }
            )
        }

        // The wedged task was cleared: the next call starts a fresh
        // load instead of awaiting the dead one (review finding #5's
        // unrecoverable-without-relaunch failure mode).
        let value = try await loader.get(
            isAvailable: { true },
            unavailableError: Unavailable(),
            load: { 7 }
        )
        #expect(value == 7)
    }

    @Test("ModelLoadTimedOut's pill message fits the 32-character overlay budget")
    func timeoutMessageFitsPill() {
        let message = ModelLoadTimedOut().errorDescription ?? ""
        #expect(!message.isEmpty)
        #expect(message.count <= 32)
    }
}

/// Minimal async gate: `wait()` suspends until `open()`.
@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    var hasWaiter: Bool { continuation != nil }

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}
