//
//  Recorder.swift
//  ora
//
//  Captures microphone input via AVAudioEngine and returns a single
//  16 kHz mono Float32 PCM buffer when recording stops. Parakeet (and
//  Whisper, later) both want exactly that format, so we do the sample-
//  rate and channel conversion here once and hand a ready-to-transcribe
//  buffer to STT rather than making every transcriber re-derive it.
//
//  ## Thread model
//
//  The whole target runs with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
//  but `start()` and `stop()` deliberately do their AVAudioEngine work on
//  a background dispatch queue and await the result. The reason is a
//  known CoreAudio deadlock pattern observed in production
//  (see investigation 2026-05-22): `engine.prepare()` and `engine.start()`
//  dispatch_sync into AVAudioIOUnit, which then mach_msg's into
//  `coreaudiod`. When `coreaudiod` stalls (sleep/wake, device hotplug,
//  daemon hang), the entire chain hangs forever. If that chain runs on
//  the main thread, the menu bar and the ESC escape hatch freeze with
//  it. Running it on a background queue keeps the UI responsive — the
//  worst case becomes "this dictation press timed out", not "the whole
//  app is dead".
//
//  AVAudioEngine's input tap callback fires on a real-time audio thread
//  owned by Core Audio — not on the main actor. That callback must stay
//  non-blocking and allocation-light, so the tap pushes raw frames into
//  a lock-guarded `SampleSink` owned by that recording session, and the
//  main-actor `stop()` drains it after the engine has been halted.
//
//  The sink is per-session (engine + sink travel together in a
//  `CaptureSession`), not a property on the Recorder. That matters for
//  two races we hit in production: (a) `cancel()` stops the recorder
//  fire-and-forget, and a quick re-press could start a new session
//  while the old stop was still draining — with a shared accumulator
//  the old drain stole and then wiped the new session's audio; (b) a
//  timed-out engine start can complete *after* the timeout fired, and
//  its tap must not write into whatever session came next.
//
//  `onLevel` follows a different pattern: it's a normal main-actor
//  stored property, **not** `nonisolated(unsafe)`. The audio thread
//  never reads `self.onLevel`. Instead, `start()` snapshots the closure
//  into a local on the main actor and threads it through the tap
//  closure, so the audio thread only ever invokes a closure value that
//  was passed to it. Invocation hops back to the main actor via
//  `DispatchQueue.main.async` (GCD's pre-concurrency bridge accepts
//  non-Sendable closure captures where `Task { @MainActor }` does not).
//
//  ## Why we recreate the AVAudioEngine on every start
//
//  Reusing one engine across many start/stop cycles was the cause of
//  the deadlock above: `AVAudioEngineImpl::IOUnitConfigurationChanged`
//  events that arrive between sessions can leave the engine's internal
//  recursive_mutex in a poisoned state. Constructing a fresh engine per
//  press is cheap (a few KB and a couple of ms) and means every
//  recording starts from a known-clean slate.
//
//  ## Format negotiation
//
//  AVAudioEngine's input node reports the hardware format (typically
//  44.1 or 48 kHz, stereo on some mics). We install the tap in that
//  native format — taps installed in a non-native format silently drop
//  buffers on some devices — and run the frames through an
//  `AVAudioConverter` into our target 16 kHz mono Float32 layout before
//  accumulating. Doing the conversion incrementally (per tap buffer)
//  rather than in one pass at the end keeps peak memory bounded and
//  means `stop()` is effectively free.
//

@preconcurrency import AVFoundation
import Foundation

@MainActor
final class Recorder {
    enum Failure: Error, LocalizedError {
        case notAuthorized
        case engineStartFailed(Error)
        case engineStartTimedOut
        case converterUnavailable
        case notRecording

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Microphone access has not been granted."
            case .engineStartFailed(let error):
                return "Audio engine failed to start: \(error.localizedDescription)"
            case .engineStartTimedOut:
                return "Audio engine took too long to start. Try again."
            case .converterUnavailable:
                return "Could not create an audio format converter."
            case .notRecording:
                return "stop() called while no recording was in progress."
            }
        }
    }

    /// Target format for everything downstream. 16 kHz mono Float32 is
    /// what Parakeet's FluidAudio frontend expects; keeping it fixed
    /// here means STT can assume it.
    ///
    /// These are `nonisolated` so the real-time tap callback (which is
    /// not MainActor-isolated) can read them without hopping actors —
    /// the default MainActor isolation at the target level would
    /// otherwise forbid it.
    nonisolated static let targetSampleRate: Double = 16_000
    nonisolated private static let targetChannels: AVAudioChannelCount = 1

    /// Upper bound on how long `engine.prepare() + engine.start()` may
    /// take before we surface a timeout. Healthy CoreAudio finishes in
    /// well under 100 ms; the timeout exists only so the rare hang
    /// surfaces as a visible error instead of an indefinite "Recording"
    /// pill. 10 s is generous on purpose — short enough that the user
    /// gives up before us, long enough that a momentarily-slow daemon
    /// doesn't false-positive.
    nonisolated private static let startTimeoutSeconds: Int = 10

    /// The live recording session (engine + its private sample sink),
    /// or nil between sessions. A fresh session is built on every
    /// `start()` so device-configuration-change events that may have
    /// poisoned the previous engine can't affect the new one, and so a
    /// stop() that races a subsequent start() drains its *own* sink
    /// instead of the new session's — see file header.
    private var session: CaptureSession?

    private let targetFormat: AVAudioFormat

    /// Called on the main actor with a 0...1 normalized RMS level for
    /// every converted tap buffer while recording. Set before `start()`.
    /// Captured by value at start() time, so mutating after start() has
    /// no effect on the in-flight recording — set it again before the
    /// next start() if you need to swap. See thread-model note for why
    /// this is a normal main-actor property and not nonisolated(unsafe).
    var onLevel: ((Float) -> Void)?

    init() {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: Self.targetChannels,
            interleaved: false
        ) else {
            // Standard PCM formats never fail to construct on Apple
            // platforms; if this ever trips it's a platform bug, not a
            // runtime condition worth recovering from.
            fatalError("Failed to construct target AVAudioFormat (16 kHz mono Float32).")
        }
        self.targetFormat = format
    }

    // MARK: - Lifecycle

    /// Begins recording from the given input device, or the system
    /// default when `deviceID` is `nil`. Must be called after
    /// `MicrophonePermission.request()` has resolved to `true` —
    /// starting the engine without authorization puts the input node
    /// into a zombie state that reports silence forever.
    ///
    /// `deviceID` is an ephemeral `AudioDeviceID` resolved just-in-time
    /// from `InputDeviceStore.resolveSelectedDeviceID()`. If applying
    /// the override fails (e.g. the device was grabbed exclusively
    /// between resolve-time and now), we log the `OSStatus` and
    /// continue with the system default — see the design spec's
    /// silent-fallback policy.
    ///
    /// Async: the engine prepare/start work happens on a background
    /// dispatch queue. See the file header for the deadlock rationale.
    func start(deviceID: AudioDeviceID? = nil) async throws {
        guard MicrophonePermission.status == .authorized else {
            throw Failure.notAuthorized
        }
        if session != nil { return }

        // Snapshot the level callback on the main actor BEFORE crossing
        // onto the engine queue. Tap callbacks invoke a closure value;
        // they never read `self.onLevel`. See thread-model note.
        let levelCallback = self.onLevel
        let targetFormat = self.targetFormat
        let sink = SampleSink()

        let newEngine = try await Self.makeAndStartEngine(
            deviceID: deviceID,
            targetFormat: targetFormat,
            levelCallback: levelCallback,
            sink: sink
        )

        // start() is only ever awaited from one coordinator press at a
        // time, but be defensive: if a session somehow appeared while
        // we were booting, prefer the existing one and drop ours.
        guard session == nil else {
            await Self.tearDownEngine(newEngine)
            return
        }
        session = CaptureSession(engine: newEngine, sink: sink)
    }

    /// Thread-safe snapshot of the 16 kHz mono Float32 samples
    /// accumulated so far. Callable mid-recording from the main actor
    /// — this is the pull-model feed for the live-preview loop
    /// (spec §5.2): the engine polls on its own cadence instead of the
    /// tap pushing chunks, so the tap, `start()`, and `stop()` keep
    /// their exact semantics. Returns `[]` when no capture session is
    /// active (between sessions, or after a racing stop already tore
    /// the session down).
    func snapshotSamples() -> [Float] {
        session?.sink.snapshot() ?? []
    }

    /// Stops recording and returns the captured audio as a single
    /// contiguous 16 kHz mono Float32 PCM buffer. Throws `.notRecording`
    /// if called without a matching `start()`.
    ///
    /// Async: the actual `engine.stop()` runs on a background dispatch
    /// queue. `stop()` can block briefly while the audio thread flushes
    /// its last buffer, and we want that wait off the main thread for
    /// the same reason as `start()`.
    func stop() async throws -> AVAudioPCMBuffer {
        guard let currentSession = session else {
            throw Failure.notRecording
        }
        session = nil

        await Self.tearDownEngine(currentSession.engine)

        // After tearDownEngine returns, the audio thread is guaranteed
        // not to touch this session's sink again — `engine.stop()`
        // blocks until the audio thread has flushed its last buffer.
        // Draining our own session's sink (not a shared accumulator)
        // means a start() that raced this stop is unaffected.
        let frames = currentSession.sink.drain()

        return Self.makeBuffer(from: frames, format: targetFormat)
    }

    // MARK: - Engine setup (off main thread)

    /// Builds a fresh AVAudioEngine, installs the input tap, calls
    /// `prepare()` + `start()`, and returns the live engine. All of
    /// that runs on a background `DispatchQueue.global` thread because
    /// any of those calls can hang the entire process when CoreAudio is
    /// in a bad state. A timer races the work and resumes with
    /// `.engineStartTimedOut` if 10 s elapse — the runaway background
    /// thread is allowed to keep dying in the background since we can't
    /// interrupt CoreAudio anyway; the next press gets a fresh thread
    /// and a fresh engine.
    ///
    /// If the timeout wins the race and the engine start *then*
    /// completes anyway, the worker detects the lost race (tryResume
    /// returns false) and tears the engine straight back down — a
    /// late-started engine must not keep the mic open or keep feeding
    /// its tap.
    nonisolated private static func makeAndStartEngine(
        deviceID: AudioDeviceID?,
        targetFormat: AVAudioFormat,
        levelCallback: ((Float) -> Void)?,
        sink: SampleSink
    ) async throws -> AVAudioEngine {
        let box = ResumeBox()

        return try await withCheckedThrowingContinuation { cont in
            box.cont = cont

            DispatchQueue.global(qos: .userInitiated).async {
                let engine = AVAudioEngine()
                let input = engine.inputNode

                // Apply the device override BEFORE reading inputFormat —
                // the hardware format is device-specific, and querying it
                // before the override would pin the pipeline to the old
                // default's format.
                if let deviceID {
                    applyInputDeviceOverride(on: input, deviceID: deviceID)
                }

                // The hardware format for the input bus. We install the
                // tap in this format and convert downstream — installing
                // a tap in a non-native format is accepted by the API
                // but behaves oddly on some USB interfaces, so don't.
                let inputFormat = input.inputFormat(forBus: 0)

                guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                    _ = box.tryResume(.failure(Failure.converterUnavailable))
                    return
                }

                // 4096 frames ≈ 85 ms at 48 kHz — small enough that a
                // tap-to-stop feels instant, large enough to avoid
                // excessive callback churn on the audio thread.
                input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
                    Self.handleTap(
                        buffer: buffer,
                        converter: converter,
                        targetFormat: targetFormat,
                        sink: sink,
                        levelCallback: levelCallback
                    )
                }

                engine.prepare()
                do {
                    try engine.start()
                } catch {
                    input.removeTap(onBus: 0)
                    _ = box.tryResume(.failure(Failure.engineStartFailed(error)))
                    return
                }
                if !box.tryResume(.success(engine)) {
                    // The 10 s timeout already resumed the continuation
                    // with .engineStartTimedOut; nobody owns this engine
                    // now. Tear it down here (we're already on a
                    // background thread) so it doesn't run forever.
                    input.removeTap(onBus: 0)
                    engine.stop()
                }
            }

            // Timeout safety net: see startTimeoutSeconds comment for
            // the rationale on the duration and leaked-thread tradeoff.
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(Self.startTimeoutSeconds)) {
                _ = box.tryResume(.failure(Failure.engineStartTimedOut))
            }
        }
    }

    /// Removes the input tap and stops the engine on a background
    /// dispatch queue. `engine.stop()` is documented as blocking until
    /// the audio thread has flushed its last buffer; that wait must not
    /// happen on the main thread. Never fails — Core Audio teardown is
    /// best-effort.
    nonisolated private static func tearDownEngine(_ engine: AVAudioEngine) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                cont.resume()
            }
        }
    }

    // MARK: - Tap handling

    /// Runs on the real-time audio thread. Converts one input buffer
    /// into the target format, appends its samples to the session's
    /// sink, and (if a `levelCallback` was snapshotted at start() time)
    /// dispatches a normalized RMS level to the main actor. Keep this
    /// path lean — no logging, no allocations beyond the converter's
    /// own scratch buffer and the GCD enqueue.
    private nonisolated static func handleTap(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        sink: SampleSink,
        levelCallback: ((Float) -> Void)?
    ) {
        // Allocate an output buffer sized to what the converter needs
        // for this input chunk. `capacity` is the worst-case frame
        // count at the target rate; the converter writes `frameLength`.
        let ratio = Self.targetSampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else { return }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            // AVAudioConverter's pull-style callback: return the source
            // buffer once, then signal end-of-stream so it flushes.
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil,
              let channel = output.floatChannelData?[0] else { return }

        let frameCount = Int(output.frameLength)
        sink.append(UnsafeBufferPointer(start: channel, count: frameCount))

        // Audio level dispatch. levelCallback was snapshotted on the
        // main actor at start() time, so we never touch self.onLevel
        // here. DispatchQueue.main.async (not Task @MainActor) is the
        // only path that compiles cleanly — Task's @Sendable check
        // rejects capturing the non-Sendable closure value.
        if let levelCallback {
            let rms = Self.computeRMS(channel, count: frameCount)
            let normalized = min(1.0, rms * 8.0)  // 8x gain so quiet speech reaches ~0.6
            DispatchQueue.main.async {
                levelCallback(normalized)
            }
        }
    }

    /// Plain RMS over a Float32 sample buffer. Returns 0 on an empty
    /// buffer (avoids the NaN that would otherwise come from 0/0 and
    /// blow up the SwiftUI waveform binding).
    private nonisolated static func computeRMS(_ samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var sumSquares: Float = 0
        for i in 0..<count {
            sumSquares += samples[i] * samples[i]
        }
        return (sumSquares / Float(count)).squareRoot()
    }

    // MARK: - Buffer assembly

    private static func makeBuffer(from frames: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer {
        let capacity = AVAudioFrameCount(max(frames.count, 1))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            // Same rationale as init(): standard PCM formats don't fail
            // to allocate under normal conditions.
            fatalError("Failed to allocate output AVAudioPCMBuffer for \(frames.count) frames.")
        }
        buffer.frameLength = AVAudioFrameCount(frames.count)
        if let channel = buffer.floatChannelData?[0], !frames.isEmpty {
            frames.withUnsafeBufferPointer { src in
                channel.update(from: src.baseAddress!, count: frames.count)
            }
        }
        return buffer
    }

    // MARK: - Device override

    /// Sets `kAudioOutputUnitProperty_CurrentDevice` on the input
    /// node's underlying audio unit. Logs and returns silently on
    /// failure — the caller continues with whatever device the unit
    /// was already bound to (typically the system default).
    nonisolated private static func applyInputDeviceOverride(
        on input: AVAudioInputNode,
        deviceID: AudioDeviceID
    ) {
        guard let audioUnit = input.audioUnit else {
            NSLog("[Recorder] inputNode.audioUnit was nil; skipping device override")
            return
        }

        var mutableID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            NSLog("[Recorder] AudioUnitSetProperty CurrentDevice failed: OSStatus=\(status); using system default")
        }
    }
}

// MARK: - CaptureSession

/// One recording session: the engine and the sink its tap writes into.
/// Built fresh on every `start()` and handed whole to `stop()`, so two
/// overlapping sessions (cancel + quick re-press) can never share
/// buffers. Main-actor owned; the sink inside is the only piece the
/// audio thread touches.
@MainActor
final class CaptureSession {
    let engine: AVAudioEngine
    let sink: SampleSink

    init(engine: AVAudioEngine, sink: SampleSink) {
        self.engine = engine
        self.sink = sink
    }
}

// MARK: - SampleSink

/// Lock-guarded accumulator for converted 16 kHz mono Float32 samples.
/// Appended on the real-time audio thread, snapshotted mid-recording by
/// the live-preview loop (main actor), and drained once on the main
/// actor after the engine has been stopped. The drain is uncontended in
/// practice (it happens strictly after the last append for a healthy
/// session); the lock earns its keep against concurrent snapshots, and
/// keeps a *leaked* session — a timed-out engine start that completes
/// late, or a stop racing a new start — memory-safe instead of
/// corrupting an Array shared across threads.
// Internal (not private) so the append/drain contract is unit-testable.
final class SampleSink: @unchecked Sendable {
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var samples: [Float] = []

    nonisolated init() {}

    nonisolated func append(_ buffer: UnsafeBufferPointer<Float>) {
        lock.lock()
        defer { lock.unlock() }
        samples.append(contentsOf: buffer)
    }

    /// Returns a copy of everything accumulated so far, leaving the
    /// storage in place for the eventual `drain()`. Called repeatedly
    /// mid-recording by the live-preview loop. The copy is forced
    /// *inside* the lock (`Array(buffer)` over the unsafe pointer, not
    /// a plain CoW `return samples`) so the O(n) memcpy is paid here on
    /// the caller's thread — a CoW share would defer the copy to the
    /// real-time audio thread's next `append`, which must stay
    /// allocation-light.
    nonisolated func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples.withUnsafeBufferPointer { Array($0) }
    }

    /// Returns everything accumulated so far and releases the storage.
    nonisolated func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let drained = samples
        samples = []
        return drained
    }
}

// MARK: - ResumeBox

/// First-resume-wins gate around a `CheckedContinuation`. The engine
/// setup work and the 10-second timeout timer both race to resume the
/// same continuation, and `CheckedContinuation` traps on double-resume,
/// so we need an external arbiter. Lock-guarded because the two
/// resumers run on different background dispatch threads.
///
/// Everything is `nonisolated` — the target's default MainActor
/// isolation would otherwise force every method onto main, which
/// defeats the whole point (a deadlock'd `coreaudiod` would still wedge
/// main when our timeout fires). The `NSLock` provides the thread
/// safety that the actor model would normally hand us.
// Internal (not private) so the first-resume-wins contract is unit-testable.
final class ResumeBox: @unchecked Sendable {
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var consumed = false
    nonisolated(unsafe) var cont: CheckedContinuation<AVAudioEngine, Error>?

    nonisolated init() {}

    /// Resumes the continuation if nobody has yet. Returns false when
    /// the race was already lost — callers holding a live resource
    /// (the started engine) use that signal to tear it down.
    nonisolated func tryResume(_ result: Result<AVAudioEngine, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !consumed, let cont else { return false }
        consumed = true
        switch result {
        case .success(let engine): cont.resume(returning: engine)
        case .failure(let error): cont.resume(throwing: error)
        }
        return true
    }
}
