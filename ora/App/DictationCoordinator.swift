//
//  DictationCoordinator.swift
//  ora
//
//  The M6 vertical slice. Owns the dictation pipeline and the overlay
//  pill, runs a four-state machine driven by the global hotkey, and
//  funnels every state change through a single transition method so
//  side effects are easy to reason about.
//
//  ## State machine
//
//      idle ──onPress──▶ [preflight]
//                           │
//                ┌──────────┴──────────┐
//                │                     │
//                ▼                     ▼
//             starting              error(_)
//                │                     │
//        engine.start awaited      (2s timer or
//          off the main thread      re-press)
//                │                     │
//                ▼                     ▼
//             recording               idle
//                │
//             onRelease
//                │
//                ▼
//          transcribing
//             │   │
//        success  failure
//             │   │
//             ▼   ▼
//           idle  error(_)
//
//  `.starting` is the window between "we kicked off engine prepare/start
//  on a background queue" and "the engine is actually running". It
//  exists because AVAudioEngine has been observed to deadlock for tens
//  of seconds when CoreAudio is unhealthy; previously that hang was on
//  the main thread and froze the menu bar. See Recorder.swift's header.
//
//  `cancel()` (ESC or overlay × click) from `starting`, `recording`, or
//  `transcribing` transitions back to `idle`, discarding the buffer and
//  any in-flight transcribe task. From `.starting`, the engine
//  teardown is deferred until the boot completes; we can't interrupt
//  AVAudioEngine mid-prepare. No-op from `idle` / `error(_)`.
//
//  While `.recording` with the panel overlay style and a preview-
//  capable model, a `LivePreviewEngine` re-transcribes the accumulated
//  buffer every ~1 s and writes the partial text into the overlay
//  state. It rides alongside the state machine rather than in it: the
//  engine is started on the transition into `.recording` and torn down
//  on every transition out, and the release path below is unchanged —
//  the final transcription never depends on the preview loop. See
//  `docs/2026-06-10-streaming-live-preview-spec.md` §5.3.
//
//  See `docs/2026-04-09-m6-dictation-coordinator-design.md` for the
//  full transitions table, the rationale for each design decision,
//  and the explicit non-goals.
//
//  ## Threading
//
//  Everything here is `@MainActor`. Carbon hotkey callbacks already
//  arrive on the main thread (HotkeyService bridges via
//  `MainActor.assumeIsolated`). The transcribe + paste pipeline runs
//  in a Task that hops to background for inference and returns to
//  main for the paste step. The error auto-dismiss is also a main-
//  actor Task using `Task.sleep`.
//

import AppKit
import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class DictationCoordinator {
    // MARK: - State

    enum State: Equatable {
        case idle
        case starting           // engine boot in flight on a background queue
        case recording
        case transcribing       // also covers the paste tail
        case error(ErrorKind)
    }

    enum ErrorKind: Equatable {
        case noMic
        case noAccessibility
        case noModel
        case generic(String)
    }

    private(set) var state: State = .idle

    // MARK: - Dependencies (owned)

    private let hotkey: HotkeyService
    private let recorder: Recorder
    private let localTranscribers: [String: any Transcriber]
    /// Cache of API transcribers keyed by catalog model id. Built lazily
    /// on first use per provider and reused for the rest of the process —
    /// each owns a dedicated URLSession (thread-safe) and nothing in
    /// `APITranscriber` holds per-call state, so one instance per
    /// provider is enough.
    private var apiTranscribers: [String: APITranscriber] = [:]
    private let paster: Paster
    private let overlay: RecordingOverlayController
    private let modelManager: ModelManager
    private let preferences: Preferences
    private let inputDeviceStore: InputDeviceStore
    private let escapeMonitor = EscapeKeyMonitor()

    // MARK: - Shared dependencies exposed for SwiftUI environments

    /// The input device store owned by this coordinator. Exposed so
    /// the app scene can inject the same instance into `MenuBarView`
    /// via `.environment(_:)` — both the menu and the record-time
    /// resolver must see the same published state.
    var inputDevices: InputDeviceStore { inputDeviceStore }

    // MARK: - In-flight task bookkeeping

    /// The transcribe + paste pipeline launched on hotkey release.
    /// Cancelled when a new pipeline starts; the coordinator is
    /// process-lifetime so we don't rely on deinit cleanup (and
    /// can't — see the comment block where the deinit used to be).
    private var transcribeTask: Task<Void, Never>?

    /// The 2s auto-dismiss timer for error states. Cancelled on every
    /// state transition that lands somewhere new, so a re-press during
    /// the error window cleanly replaces it.
    private var errorDismissTask: Task<Void, Never>?

    /// The live-preview loop for the panel overlay (spec §5.3).
    /// Non-nil only while a panel-style recording with a preview-
    /// capable model is in flight. Stopped by `transition(to:)` on
    /// every move out of `.recording`, and explicitly at the top of
    /// `stopRecordingAndTranscribe()` so no new preview round can
    /// queue ahead of the final transcription on the backend's actor.
    private var previewEngine: LivePreviewEngine?

    /// Debounce timer for prewarm-on-select. Cancelled and replaced on
    /// every selection change so only the model the user settles on gets
    /// warmed (and pinned in memory) — see `schedulePrewarmOnSelect`.
    private var prewarmDebounceTask: Task<Void, Never>?

    /// True when a stop request arrived while we were still in
    /// `.starting` — a PTT release, or the second press in toggle mode.
    /// We can't act on it immediately because the engine hasn't
    /// finished booting; the starting Task observes this flag right
    /// after `await recorder.start(...)` returns and runs the same
    /// stop+transcribe tail it would have from `.recording`. Almost
    /// always produces a too-short recording that returns silently to
    /// `.idle` — that's fine; the alternative (ignoring the request
    /// entirely) would leave the user stuck in `.recording` until they
    /// pressed again.
    private var stopRequestedDuringStart = false

    /// Monotonic id for dictation attempts. Bumped by every new press
    /// and by `cancel()`. The engine-boot Task captures the value when
    /// it launches and re-checks it after `recorder.start` returns, so
    /// a boot that resolves late (cancel, or cancel + quick re-press,
    /// happened meanwhile) can't act on a newer attempt's `.starting`
    /// state or clobber it with a stale error.
    private var dictationGeneration = 0

    // MARK: - Init

    /// Shared singleton used by AppDelegate and DictationPage.
    static let shared = DictationCoordinator()

    /// Convenience init used at app launch. Constructs every dependency
    /// inside the main-actor body so default-argument evaluation never
    /// crosses an isolation boundary (which trips strict-concurrency).
    private convenience init() {
        let fluidDownloader = FluidAudioDownloader()
        let mlxDownloader = MLXModelDownloader()
        self.init(
            hotkey: HotkeyService(),
            recorder: Recorder(),
            localTranscribers: [
                "parakeet-v3": FluidAudioTranscriber(downloader: fluidDownloader),
                "parakeet-v2": FluidAudioTranscriber(modelId: "parakeet-v2", downloader: fluidDownloader),
                NemotronUnifiedTranscriber.modelId: NemotronUnifiedTranscriber(downloader: fluidDownloader, preferences: .shared),
                NemotronStreamingTranscriber.modelId: NemotronStreamingTranscriber(downloader: fluidDownloader, preferences: .shared),
                SenseVoiceTranscriber.modelId: SenseVoiceTranscriber(downloader: fluidDownloader),
                "qwen3-asr-0.6b": MLXTranscriber(modelId: "qwen3-asr-0.6b", downloader: mlxDownloader),
                "qwen3-asr-1.7b": MLXTranscriber(modelId: "qwen3-asr-1.7b", downloader: mlxDownloader),
            ],
            paster: Paster(),
            overlay: RecordingOverlayController(),
            modelManager: .shared,
            preferences: .shared,
            inputDeviceStore: InputDeviceStore(preferences: .shared)
        )
    }

    /// Designated init used by tests / harnesses to inject fakes. No
    /// default arguments — see `convenience init()` above for the
    /// reason.
    init(
        hotkey: HotkeyService,
        recorder: Recorder,
        localTranscribers: [String: any Transcriber],
        paster: Paster,
        overlay: RecordingOverlayController,
        modelManager: ModelManager,
        preferences: Preferences,
        inputDeviceStore: InputDeviceStore
    ) {
        self.hotkey = hotkey
        self.recorder = recorder
        self.localTranscribers = localTranscribers
        self.paster = paster
        self.overlay = overlay
        self.modelManager = modelManager
        self.preferences = preferences
        self.inputDeviceStore = inputDeviceStore
    }

    // No deinit: under strict concurrency a `@MainActor` class's deinit
    // is nonisolated and cannot touch the in-flight task properties.
    // The coordinator is process-lifetime in practice so the defensive
    // cancellation buys nothing — drop it rather than fight the
    // isolation rules.

    // MARK: - Lifecycle

    /// Prewarms a model's pipeline off the first-dictation path at the
    /// moment a freshly-downloaded model becomes usable — load + the
    /// heavy first-inference cost (CoreML specialization / Metal JIT)
    /// happen while the user is still on the Models page, not on their
    /// next hotkey press (see `Transcriber.prewarm()`). Every *local*
    /// backend prewarms; cloud models have no
    /// transcriber in `localTranscribers`, so they're skipped here.
    func wirePrewarmOnDownload() {
        modelManager.onDownloadComplete = { [weak self] id in
            guard let self, let transcriber = self.localTranscribers[id] else { return }
            Task { await transcriber.prewarm() }
        }
    }

    /// Prewarms whenever the selected model changes. Without this,
    /// switching to an already-downloaded model leaves the full cold
    /// load on the first dictation after the switch — the download hook
    /// fires only once, at download time, so a model picked in a later
    /// session never gets warmed otherwise. Debounced (see
    /// `schedulePrewarmOnSelect`) because selecting is a single tap on a
    /// downloaded card and a loaded model stays resident for the whole
    /// process lifetime.
    func wirePrewarmOnModelSelect() {
        preferences.onSelectedModelChanged = { [weak self] _ in
            self?.schedulePrewarmOnSelect()
        }
        // The Nemotron language is baked into the loaded encoder, so a
        // change means a reload — warm it now (same debounce: flicking
        // through the picker only reloads for the language settled on)
        // instead of on the next dictation. A no-op unless Nemotron is
        // the selected model.
        preferences.onNemotronUnifiedLanguageChanged = { [weak self] in
            self?.schedulePrewarmOnSelect()
        }
    }

    /// Debounces prewarm-on-select: each selection change cancels the
    /// previous pending prewarm and arms a new one, so tapping through
    /// several downloaded model cards only warms the one the user
    /// settles on. This matters because `LazyLoader` never evicts —
    /// every model it loads stays resident for the process lifetime, so
    /// eagerly warming each card browsed past would pin several GB of
    /// models the user never dictates with. The launch and
    /// download-complete prewarms aren't debounced: each is a single,
    /// deliberate "this model just became the one to use" signal.
    private func schedulePrewarmOnSelect() {
        prewarmDebounceTask?.cancel()
        prewarmDebounceTask = Task { [weak self] in
            // Long enough to skip a fast tap-through, short enough that a
            // deliberate single switch is warm by the next dictation.
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.prewarmSelectedModel()
        }
    }

    /// Kicks off a background prewarm of the currently-selected model
    /// when it's a local backend. Called directly at launch (for the
    /// selection restored from UserDefaults, so the first dictation of a
    /// session is warm too) and, debounced, on every selection change.
    /// No-op for cloud / unknown ids; best-effort — a not-yet-downloaded
    /// model just fails the prewarm silently and loads lazily on first
    /// use as before.
    func prewarmSelectedModel() {
        let id = preferences.selectedModelId ?? Preferences.defaultModelId
        guard modelManager.catalog.first(where: { $0.id == id })?.isLocal == true,
              let transcriber = localTranscribers[id] else { return }
        Task { await transcriber.prewarm() }
    }

    /// Wires the post-download prewarm hook, the audio level callback,
    /// the cancel hooks (overlay hover click + ESC monitor), and the
    /// global hotkey, then starts listening for press/release. Call
    /// once at app launch from `AppDelegate.applicationDidFinishLaunching`.
    func start() {
        wirePrewarmOnDownload()
        wirePrewarmOnModelSelect()

        recorder.onLevel = { [weak self] level in
            self?.overlay.state.audioLevel = level
        }

        overlay.onCancel = { [weak self] in
            self?.cancel()
        }

        escapeMonitor.onEscape = { [weak self] in
            self?.cancel()
        }

        hotkey.onPress = { [weak self] in
            self?.handlePress()
        }
        hotkey.onRelease = { [weak self] in
            self?.handleRelease()
        }

        // CGEventTap requires Accessibility permission. Don't create
        // the tap until it's been granted — otherwise the system shows
        // its own TCC popup, bypassing our onboarding flow.
        if Paster.isTrusted {
            hotkey.register(preferences.activationKey)
        } else {
            waitForAccessibility()
        }

        // Warm the restored selection in the background so the first
        // dictation of the session doesn't pay the cold load. Spawns its
        // own Task — never blocks launch.
        prewarmSelectedModel()
    }

    /// Polls until Accessibility is granted, then registers the hotkey.
    /// Self-cancelling — stops as soon as the tap is created.
    private func waitForAccessibility() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { break }
                if Paster.isTrusted {
                    self.hotkey.register(self.preferences.activationKey)
                    return
                }
            }
        }
    }

    /// Registers (or re-registers) the hotkey with the current
    /// preference. Called from DictationPage when the user changes the
    /// shortcut, and from onboarding when accessibility is granted.
    func updateHotkey() {
        guard Paster.isTrusted else { return }
        hotkey.register(preferences.activationKey)
    }

    // MARK: - Hotkey handlers

    private func handlePress() {
        switch Self.pressAction(from: state, mode: preferences.activationMode) {
        case .startDictation:
            // Error is treated as a decorated idle: cancel the dismiss
            // timer and re-run preflight from the top. See design doc
            // § Why error(_) accepts re-press immediately.
            errorDismissTask?.cancel()
            errorDismissTask = nil
            startNewDictation()

        case .requestStopAfterBoot:
            stopRequestedDuringStart = true

        case .stopAndTranscribe:
            Task { await stopRecordingAndTranscribe() }

        case .ignore:
            break
        }
    }

    private func handleRelease() {
        switch Self.releaseAction(from: state, mode: preferences.activationMode) {
        case .stopAndTranscribe:
            Task { await stopRecordingAndTranscribe() }

        case .requestStopAfterBoot:
            stopRequestedDuringStart = true

        case .ignore:
            break
        }
    }

    // MARK: - Press / release decision tables

    /// What a hotkey press should do, given the current state and
    /// activation mode. Pure — extracted so the decision table is
    /// unit-testable (see DictationCoordinatorDecisionTests), same
    /// pattern as `handleCancel(from:)`.
    enum PressAction: Equatable {
        case startDictation       // run preflight + engine boot
        case requestStopAfterBoot // toggle stop while engine still booting
        case stopAndTranscribe    // toggle stop while recording
        case ignore
    }

    static func pressAction(from state: State, mode: ActivationMode) -> PressAction {
        switch state {
        case .idle, .error:
            return .startDictation

        case .starting:
            // Hold: release is the stop signal; a press here is noise.
            // Toggle: this press *is* the stop — but the engine is
            // still booting, so the stop is deferred until the boot
            // resolves (same mechanism as a hold-release mid-boot).
            return mode == .toggle ? .requestStopAfterBoot : .ignore

        case .recording:
            // Hold: release is the canonical stop; a second press is
            // noise. Toggle: second press is the stop.
            return mode == .toggle ? .stopAndTranscribe : .ignore

        case .transcribing:
            // Busy — the transcribing tail owns the next transition.
            return .ignore
        }
    }

    /// What a hotkey release should do. Pure; counterpart to
    /// `pressAction(from:mode:)`.
    enum ReleaseAction: Equatable {
        case stopAndTranscribe
        case requestStopAfterBoot
        case ignore
    }

    static func releaseAction(from state: State, mode: ActivationMode) -> ReleaseAction {
        // In toggle mode the key going up is never a signal — we wait
        // for the next press.
        guard mode == .hold else { return .ignore }
        switch state {
        case .recording:
            return .stopAndTranscribe
        case .starting:
            // Release arrived while the engine is still booting; the
            // starting Task runs the stop tail once the boot resolves.
            return .requestStopAfterBoot
        case .idle, .transcribing, .error:
            // No matching record start, or already past it.
            return .ignore
        }
    }

    /// Shared stop-and-transcribe tail used by both the hold-mode
    /// release and the toggle-mode second press. Keeping this in one
    /// place means the too-short guard and the error mapping stay in
    /// sync across both input modes.
    private func stopRecordingAndTranscribe() async {
        // A cancel() can slip in between the stop trigger (release /
        // toggle press) and this Task body actually running — in that
        // case the coordinator is already .idle and the recorder torn
        // down. Don't resurrect the pipeline and don't surface the
        // resulting `.notRecording` as an error pill.
        guard Self.stopTailMayProceed(from: state) else { return }

        // Kill the preview loop before anything else. A round already
        // in flight finishes on the backend's serial actor and delays
        // the final pass by at most one inference (~0.2–0.6 s, spec
        // §5.3 — accepted), but no NEW round may start and queue ahead
        // of it. The transition(to:) safety net below would also catch
        // this, just later — after the engine-teardown await.
        stopLivePreview()

        do {
            let buffer = try await recorder.stop()

            // Re-check after the await: cancel() may have fired while
            // the engine was flushing its last buffer.
            guard Self.stopTailMayProceed(from: state) else { return }

            // Too-short recordings (< 0.3 s) contain no usable speech
            // and make Parakeet throw an inference error. Treat them
            // the same as empty audio — silent return to idle.
            let durationSeconds = Double(buffer.frameLength) / Recorder.targetSampleRate
            if durationSeconds < 0.3 {
                transition(to: .idle)
                return
            }

            transition(to: .transcribing)
            startTranscribePipeline(buffer: buffer)
        } catch {
            // .notRecording means a racing cancel/stop already released
            // the recorder — that's a clean outcome, not an error.
            if let failure = error as? Recorder.Failure, case .notRecording = failure {
                if Self.stopTailMayProceed(from: state) { transition(to: .idle) }
                return
            }
            guard Self.stopTailMayProceed(from: state) else { return }
            transition(to: .error(.generic(Self.shortMessage(for: error))))
        }
    }

    /// Whether the stop+transcribe tail may act on the current state.
    /// Pure guard shared by the entry check and the two post-await
    /// re-checks in `stopRecordingAndTranscribe` — anything other than
    /// an active recording (or one still booting) means a cancel or a
    /// competing stop got there first.
    static func stopTailMayProceed(from state: State) -> Bool {
        state == .recording || state == .starting
    }

    // MARK: - Cancel

    /// Aborts the current dictation. Drops the recording buffer (no
    /// transcribe), cancels any in-flight transcribe task (no paste,
    /// no success chime), and returns the overlay to idle. Idempotent;
    /// no-op from `.idle` and `.error`.
    ///
    /// Called from the ESC key monitor and the overlay's hover-cancel
    /// control. See `docs/superpowers/specs/2026-04-19-cancel-dictation-design.md`.
    func cancel() {
        guard Self.handleCancel(from: state) == .act else { return }

        // Invalidate any in-flight engine-boot Task: when its await
        // resolves it sees the generation mismatch and releases the
        // engine instead of acting on whatever state came next.
        dictationGeneration += 1

        switch state {
        case .recording:
            // The buffer is returned but intentionally dropped. stop()
            // is the only way to tear down the AVAudioEngine tap, so
            // we fire-and-forget it even though we don't want the audio.
            // No need to await — the engine teardown can race the rest
            // of cancel() since we never read the result.
            Task { _ = try? await self.recorder.stop() }

        case .starting:
            // AVAudioEngine can't be interrupted mid-prepare. The
            // starting Task observes the generation bump above and
            // tears down the engine on its own once
            // `recorder.start(...)` finally returns (or times out).
            break

        case .transcribing, .idle, .error:
            // No recorder resources to release here.
            break
        }

        transcribeTask?.cancel()
        transcribeTask = nil
        transition(to: .idle)
    }

    // MARK: - Press path: preflight + recorder.start

    private func startNewDictation() {
        // 1. Microphone permission
        switch MicrophonePermission.status {
        case .notDetermined:
            // Fire-and-forget: shows the system dialog. The current
            // press is doomed (the user can't grant + we can't await
            // a sync hotkey callback), but the next press after the
            // user clicks Allow will hit the happy path.
            Task { _ = await MicrophonePermission.request() }
            transition(to: .error(.noMic))
            return
        case .denied:
            transition(to: .error(.noMic))
            return
        case .authorized:
            break
        }

        // 2. Accessibility (paste) permission
        if !Paster.isTrusted {
            // Fire-and-forget: opens the System Settings list and
            // adds Ora to it. The user has to enable us manually,
            // then re-press.
            _ = Paster.requestTrust(prompt: true)
            transition(to: .error(.noAccessibility))
            return
        }

        // 3. Selected model installed (local) or configured (API)?
        let selectedId = preferences.selectedModelId ?? Preferences.defaultModelId
        guard let entry = modelManager.catalog.first(where: { $0.id == selectedId }) else {
            transition(to: .error(.noModel))
            return
        }
        if entry.isLocal {
            if !modelManager.isInstalled(selectedId) {
                transition(to: .error(.noModel))
                return
            }
        } else {
            // Online model: a missing key or model name is a config
            // problem, not a "download me" problem — surface it as a
            // generic pill that points at the settings sheet.
            if !apiModelIsConfigured(providerId: selectedId) {
                transition(to: .error(.generic("Configure API in Settings")))
                return
            }
        }

        // 4. Start recording. This is the only check that needs to
        //    talk to AVAudioEngine — anything that goes wrong from
        //    here is generic.
        //
        //    Resolving the device ID here (rather than once at launch)
        //    re-enumerates HAL so a reconnected device picks up the
        //    pinned selection again, and a disappeared device silently
        //    falls back to the system default.
        //
        //    `recorder.start` runs the actual engine prepare/start on a
        //    background queue (see Recorder.swift header for why), so
        //    we transition to `.starting` immediately to show the
        //    recording overlay and accept ESC, and the await happens in
        //    a detached Task. Release / cancel that arrive during the
        //    boot window flag themselves and the Task observes the new
        //    state when the await resolves.
        stopRequestedDuringStart = false
        dictationGeneration += 1
        let generation = dictationGeneration
        let deviceID = inputDeviceStore.resolveSelectedDeviceID()
        transition(to: .starting)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.recorder.start(deviceID: deviceID)
            } catch {
                // start() may have failed AFTER the user cancelled (or
                // after a newer press took over) — don't clobber their
                // state with a stale error pill.
                if generation == self.dictationGeneration, case .starting = self.state {
                    self.transition(to: .error(.generic(Self.shortMessage(for: error))))
                }
                return
            }

            let resolution = Self.bootResolution(
                generationMatches: generation == self.dictationGeneration,
                state: self.state,
                stopRequested: self.stopRequestedDuringStart
            )
            switch resolution {
            case .beginRecording:
                self.transition(to: .recording)

            case .runStopTail:
                // The stop signal (hold-release / toggle re-press)
                // arrived mid-boot. Run the normal stop+transcribe
                // tail; the duration guard will catch a too-short
                // buffer and bounce back to .idle silently.
                await self.stopRecordingAndTranscribe()

            case .releaseEngine:
                Task { _ = try? await self.recorder.stop() }

            case .ignore:
                break
            }
        }
    }

    /// What the engine-boot Task should do once `recorder.start`
    /// returns successfully, given whether its dictation attempt is
    /// still the current one, the coordinator state it observes, and
    /// whether a stop request arrived mid-boot. Pure — extracted so
    /// the decision table is unit-testable.
    ///
    /// The subtle row is stale + active state: a cancel *and* a newer
    /// press happened while we booted. The newer press's `start()`
    /// found our engine already running and adopted the session, so a
    /// stale boot must NOT release it — only when nothing newer owns
    /// the recorder (.idle / .error) does the stale boot clean up.
    enum BootResolution: Equatable {
        case beginRecording  // transition .starting → .recording
        case runStopTail     // stop request arrived mid-boot
        case releaseEngine   // nobody wants this engine; stop it
        case ignore          // a newer attempt owns the recorder
    }

    static func bootResolution(
        generationMatches: Bool,
        state: State,
        stopRequested: Bool
    ) -> BootResolution {
        guard generationMatches else {
            switch state {
            case .idle, .error: return .releaseEngine
            case .starting, .recording, .transcribing: return .ignore
            }
        }
        switch state {
        case .starting:
            return stopRequested ? .runStopTail : .beginRecording
        case .idle, .recording, .transcribing, .error:
            // Shouldn't be reachable — every same-generation exit from
            // .starting goes through cancel() (which bumps the
            // generation) or this Task — but be defensive: drop the
            // engine, leave state alone.
            return .releaseEngine
        }
    }

    // MARK: - Release path: transcribe + paste pipeline

    private func startTranscribePipeline(buffer: AVAudioPCMBuffer) {
        let selectedId = preferences.selectedModelId ?? Preferences.defaultModelId
        guard let transcriber = resolveTranscriber(for: selectedId) else {
            transition(to: .error(.noModel))
            return
        }
        // One line per dictation so you can tell from Console which
        // backend actually ran — local vs. which API provider.
        let backend: String
        if transcriber is FluidAudioTranscriber || transcriber is NemotronUnifiedTranscriber
            || transcriber is NemotronStreamingTranscriber || transcriber is SenseVoiceTranscriber { backend = "local/ane" }
        else if transcriber is MLXTranscriber { backend = "local/gpu" }
        else { backend = "api" }
        print("[ora] transcribe route=\(backend) model=\(selectedId)")
        transcribeTask?.cancel()
        transcribeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await transcriber.transcribe(buffer)

                // Cancelled mid-transcribe (by cancel()): coordinator
                // has already transitioned to .idle. Do not paste, do
                // not play the chime.
                if Task.isCancelled { return }

                // The transcriber holds main-actor isolation, so we're
                // already back on main here. Empty result is treated
                // as success-with-nothing-to-paste.
                if text.isEmpty {
                    self.transition(to: .idle)
                    return
                }

                if self.preferences.autoPaste {
                    try await self.paster.paste(text)
                } else {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                }

                // `paster.paste` awaits a 150 ms sleep (for the target
                // app to read the pasteboard before we restore it). If
                // cancel() fires during that window the Cmd+V has
                // already been posted — we can't un-paste — but we can
                // still suppress the success chime and the redundant
                // second idle transition.
                if Task.isCancelled { return }

                self.playSuccessSoundIfEnabled()
                self.transition(to: .idle)
            } catch {
                // Cancelled mid-transcribe: the thrown error (often a
                // wrapped CancellationError from URLSession) is noise.
                // Coordinator is already .idle; swallow without pill.
                if Task.isCancelled { return }

                // Side effect that can't live in the pure mapping function:
                // re-prompt for Accessibility if it was revoked mid-dictation.
                if let pasterFailure = error as? Paster.Failure,
                   case .accessibilityNotTrusted = pasterFailure {
                    _ = Paster.requestTrust(prompt: true)
                }
                self.transition(to: Self.stateForPipelineError(error))
            }
        }
    }

    // MARK: - Transcriber selection

    /// Picks (and caches) the right `Transcriber` for a catalog id.
    /// Returns `nil` when the id is unknown or refers to an online
    /// provider we don't have an adapter for — callers should map that
    /// to the `.noModel` error so the overlay shows something useful.
    private func resolveTranscriber(for modelId: String) -> (any Transcriber)? {
        guard let entry = modelManager.catalog.first(where: { $0.id == modelId }) else {
            return nil
        }
        if entry.isLocal {
            return localTranscribers[modelId]
        }
        if let cached = apiTranscribers[modelId] {
            return cached
        }
        guard let provider = APITranscriber.provider(for: modelId) else {
            return nil
        }
        let transcriber = APITranscriber(provider: provider)
        apiTranscribers[modelId] = transcriber
        return transcriber
    }

    // MARK: - Live preview (panel overlay)

    /// Whether the model selected *right now* is fast enough for the
    /// preview loop. Resolved just-in-time from the catalog, the same
    /// pattern as the transcriber/device resolution — switching models
    /// mid-recording only affects the next dictation.
    private func selectedModelSupportsLivePreview() -> Bool {
        let selectedId = preferences.selectedModelId ?? Preferences.defaultModelId
        return modelManager.catalog.first(where: { $0.id == selectedId })?.supportsLivePreview ?? false
    }

    /// Spins up the preview loop on entry to `.recording` — but only
    /// when the panel style is selected AND the model supports preview
    /// (spec §5.3: style + capability are both required; pill or an
    /// unsupported model means zero new work on the existing path).
    ///
    /// The engine reuses the exact transcriber instance the final pass
    /// will use, so the shared LazyLoader loads the model once. Note
    /// the backend actor (AsrManager) is reentrant like any Swift
    /// actor — a final pass can interleave with an in-flight preview
    /// round rather than strictly queue behind it. That's safe because
    /// each call gets its own TdtDecoderState and the shared state
    /// (models, vocabulary) is read-only after load; interleaving only
    /// shortens the release-to-paste delay.
    private func startLivePreviewIfEligible() {
        stopLivePreview()
        guard preferences.overlayStyle == .panel,
              selectedModelSupportsLivePreview() else {
            NSLog(
                "[LivePreview] not eligible: style=%@ supports=%d",
                preferences.overlayStyle.rawValue, selectedModelSupportsLivePreview() ? 1 : 0)
            return
        }
        let selectedId = preferences.selectedModelId ?? Preferences.defaultModelId
        guard let transcriber = resolveTranscriber(for: selectedId) else {
            NSLog("[LivePreview] no transcriber for %@", selectedId)
            return
        }
        NSLog("[LivePreview] starting engine for %@", selectedId)

        let engine = LivePreviewEngine(transcriber: transcriber)
        previewEngine = engine
        engine.start(
            snapshot: { [recorder] in recorder.snapshotSamples() },
            onPartial: { [weak self] text in
                self?.overlay.state.partialText = text
            }
        )
    }

    /// Idempotent teardown of the preview loop. The discarded partial
    /// text stays in the overlay state on purpose — the panel keeps
    /// the last frame on screen through the transcribing tail instead
    /// of collapsing (spec §5.4); `.starting` clears it on the next
    /// dictation.
    private func stopLivePreview() {
        previewEngine?.stop()
        previewEngine = nil
    }

    /// True when the keychain has a key *and* UserDefaults has a model
    /// name for this provider — both are required for a usable request,
    /// and both are populated by `APIModelCard`'s settings sheet.
    private func apiModelIsConfigured(providerId: String) -> Bool {
        guard KeychainStore.apiKey(provider: providerId) != nil else { return false }
        let modelKey = APITranscriber.modelDefaultsKey(for: providerId)
        let modelName = UserDefaults.standard.string(forKey: modelKey) ?? ""
        return !modelName.isEmpty
    }

    // MARK: - State transitions

    /// The single mutation point. Every code path that wants to change
    /// `state` goes through here so the side effects (overlay update,
    /// error dismiss timer) live in exactly one place.
    private func transition(to newState: State) {
        state = newState

        // The preview loop only ever runs during `.recording`; any
        // move to another state — release, cancel, error, too-short —
        // tears it down. Living at the single mutation point means no
        // exit path can forget. (The release path also stops it
        // earlier, before the recorder drain; see
        // `stopRecordingAndTranscribe`.)
        if newState != .recording { stopLivePreview() }

        switch newState {
        case .idle:
            errorDismissTask?.cancel()
            errorDismissTask = nil
            escapeMonitor.disable()
            dismiss()

        case .starting:
            // Visually identical to .recording — the boot window is
            // sub-100ms on a healthy system, so showing a distinct
            // "preparing" phase would just flicker. ESC still works
            // here; cancel() routes to the .starting branch.
            errorDismissTask?.cancel()
            errorDismissTask = nil
            escapeMonitor.enable()
            // Fresh dictation: clear the previous partial and resolve
            // the model's preview capability just-in-time (same timing
            // as the model/device resolution at press) so the panel
            // overlay picks its compact vs. full form before it shows.
            overlay.state.partialText = ""
            overlay.state.supportsLivePreview = selectedModelSupportsLivePreview()
            present(.recording)

        case .recording:
            errorDismissTask?.cancel()
            errorDismissTask = nil
            escapeMonitor.enable()
            present(.recording)
            startLivePreviewIfEligible()

        case .transcribing:
            errorDismissTask?.cancel()
            errorDismissTask = nil
            escapeMonitor.enable()
            present(.transcribing)

        case .error(let kind):
            escapeMonitor.disable()
            present(overlayPhase(for: kind))
            scheduleErrorDismiss()
        }
    }

    private func overlayPhase(for kind: ErrorKind) -> OverlayPhase {
        switch kind {
        case .noMic: return .errorNoMic
        case .noAccessibility: return .errorNoAccessibility
        case .noModel: return .errorNoModel
        case .generic(let msg): return .errorGeneric(msg)
        }
    }

    /// Plays the user's chosen notification sound, if enabled.
    /// Called from the paste-success arm of the transcribe pipeline —
    /// empty-audio / inference-failed / too-short paths all silently
    /// return to idle and should NOT trigger a chime.
    private func playSuccessSoundIfEnabled() {
        guard preferences.notificationSoundEnabled else { return }
        NSSound(named: preferences.notificationSoundName)?.play()
    }

    private func scheduleErrorDismiss() {
        errorDismissTask?.cancel()
        errorDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            // Only dismiss if we're still in an error state. A re-press
            // that landed us back in .recording shouldn't be wiped out
            // by a stale dismiss task.
            if case .error = self.state {
                self.transition(to: .idle)
            }
        }
    }

    // MARK: - Overlay helpers (the present/dismiss contract)

    /// Sets the overlay's visible phase, picking between the
    /// idempotent panel creator (`show(phase:)`) and live state
    /// mutation (`state.phase = X`) based on whether the panel is
    /// already on screen. See design doc § Overlay API contract.
    private func present(_ phase: OverlayPhase) {
        if overlay.isShowing {
            overlay.state.phase = phase
        } else {
            overlay.show(phase: phase)
        }
    }

    /// Removes the overlay panel from screen. Called on the idle
    /// transition.
    private func dismiss() {
        overlay.hide()
    }

    // MARK: - Pipeline error → state mapping

    /// Maps a transcribe/paste pipeline error to the coordinator state
    /// it should produce. Pure function — no side effects. The caller
    /// is responsible for any side effects (e.g., re-requesting
    /// Accessibility trust on `Paster.Failure.accessibilityNotTrusted`).
    ///
    /// Extracted so the error-mapping contract can be unit-tested
    /// without constructing a full coordinator or triggering system
    /// calls. See `DictationCoordinatorErrorMappingTests`.
    static func stateForPipelineError(_ error: Error) -> State {
        switch error {
        case let failure as TranscriberError:
            switch failure {
            case .modelNotDownloaded: return .error(.noModel)
            case .emptyAudio, .inferenceFailed: return .idle
            case .loadFailed: return .error(.generic(shortMessage(for: failure)))
            }
        case let failure as APITranscriber.Failure:
            switch failure {
            case .missingAPIKey, .missingModel:
                return .error(.generic("Configure API in Settings"))
            case .emptyAudio:
                return .idle
            case .network, .httpStatus, .decodingFailed, .encodingFailed:
                return .error(.generic(shortMessage(for: failure)))
            }
        case let failure as Paster.Failure:
            switch failure {
            case .accessibilityNotTrusted: return .error(.noAccessibility)
            case .eventCreationFailed: return .error(.generic(shortMessage(for: failure)))
            }
        default:
            return .error(.generic(shortMessage(for: error)))
        }
    }

    // MARK: - Cancel decision

    /// Pure predicate used by `cancel()` to decide whether to act on
    /// the current state or no-op. Extracted so the decision table is
    /// unit-testable without constructing a full coordinator.
    enum CancelDecision: Equatable {
        case act      // stop recorder (if recording), cancel transcribeTask, go to .idle
        case ignore   // no-op
    }

    static func handleCancel(from state: State) -> CancelDecision {
        switch state {
        case .starting, .recording, .transcribing: return .act
        case .idle, .error: return .ignore
        }
    }

    // MARK: - Error message formatting

    /// Caps an error's localized description at 32 characters so the
    /// generic-error pill stays visually narrow. Cuts mid-word; v0.1
    /// nit, M7 polish.
    static func shortMessage(for error: Error) -> String {
        let raw = error.localizedDescription
        return String(raw.prefix(32))
    }
}
