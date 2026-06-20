//
//  LazyLoader.swift
//  ora
//
//  Generic load-once helper used by all local transcribers. Caches
//  the loaded value and coalesces concurrent callers into a single
//  in-flight task. On failure the task is cleared so a retry can
//  re-attempt (e.g. after the user re-downloads a model).
//
//  ## Watchdog
//
//  `load()` can wedge: CoreML specialization has been observed to
//  hang, and `fromPretrained` can touch the network even when the
//  cache looks complete. Without a bound, the hung task stays set
//  forever and every later dictation awaits it — unrecoverable short
//  of relaunching. Every awaiter therefore races the shared task
//  against a watchdog; on timeout the loader throws ModelLoadTimedOut
//  and clears `task` so the next attempt starts fresh. The hung load
//  itself can't be interrupted (same tradeoff as Recorder's engine
//  timeout) — it's abandoned, and its eventual result is discarded.
//

import Foundation

/// Thrown when a model load exceeds the watchdog timeout. Top-level
/// (not nested in LazyLoader) so callers and tests don't need to spell
/// the generic specialization. The message fits the overlay pill's
/// 32-character budget.
struct ModelLoadTimedOut: Error, LocalizedError {
    var errorDescription: String? { "Model load timed out. Try again" }
}

@MainActor
final class LazyLoader<T> {
    private var value: T?
    private var task: Task<T, Error>?

    /// Upper bound on how long one `get()` waits for the load. The
    /// default is deliberately generous — WhisperKit's first-load
    /// CoreML specialization can legitimately run 1–2 minutes on older
    /// machines; the watchdog exists to recover from genuine wedges,
    /// not to police slow loads. Injectable for tests.
    private let loadTimeout: Duration

    init(loadTimeout: Duration = .seconds(300)) {
        self.loadTimeout = loadTimeout
    }

    /// Returns the cached value, or loads it via `load()` on first call.
    /// Concurrent callers share a single in-flight task.
    /// On failure or watchdog timeout the task is cleared so a retry
    /// can re-attempt.
    func get(
        isAvailable: () -> Bool,
        unavailableError: Error,
        load: @escaping () async throws -> sending T
    ) async throws -> T {
        if let value { return value }
        if let task {
            do {
                return try await awaitWithWatchdog(task)
            } catch {
                clearOnFailure(task, error: error)
                throw error
            }
        }

        guard isAvailable() else { throw unavailableError }

        let task = Task<T, Error> { try await load() }
        self.task = task

        do {
            let loaded = try await awaitWithWatchdog(task)
            value = loaded
            if self.task == task { self.task = nil }
            return loaded
        } catch {
            clearOnFailure(task, error: error)
            throw error
        }
    }

    /// Clears `task` so future calls retry — unless the error is the
    /// *waiter's own* cancellation (the user cancelled their dictation;
    /// the shared load is still perfectly good for the next caller).
    /// A CancellationError thrown by the load itself, on the other
    /// hand, is a failed load and must clear like any other error.
    private func clearOnFailure(_ task: Task<T, Error>, error: Error) {
        if error is CancellationError && Task.isCancelled { return }
        if self.task == task { self.task = nil }
    }

    /// Awaits the shared load task, but never longer than
    /// `loadTimeout`. Implemented as two main-actor watcher tasks
    /// racing to resume one continuation (first-wins, arbitrated by a
    /// main-actor flag) because `Task.value` itself cannot be
    /// interrupted and the loaded `T` is not Sendable — the value is
    /// re-read from `task.value` only after the race says it finished,
    /// so it never crosses isolation.
    private func awaitWithWatchdog(_ task: Task<T, Error>) async throws -> T {
        let timeout = loadTimeout
        let race = RaceState()

        let finished: Bool = await withCheckedContinuation { cont in
            let watchdog = Task { @MainActor in
                try? await Task.sleep(for: timeout)
                guard !race.resumed else { return }
                race.resumed = true
                cont.resume(returning: false)
            }
            Task { @MainActor in
                _ = try? await task.value
                guard !race.resumed else { return }
                race.resumed = true
                watchdog.cancel()
                cont.resume(returning: true)
            }
        }

        guard finished else { throw ModelLoadTimedOut() }
        // The task has completed; this resumes immediately and
        // propagates the load error if it failed.
        return try await task.value
    }
}

/// First-wins flag for the watchdog race. Main-actor (not a lock):
/// both watcher tasks are main-actor isolated, so reads/writes are
/// serialized by the actor.
@MainActor
private final class RaceState {
    var resumed = false
}
