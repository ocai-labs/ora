//
//  ModelManager.swift
//  ora
//
//  Source of truth for the local + API model catalog. Owns per-entry
//  status, download Tasks, and the FluidAudio and MLX adapters. UI reads
//  `catalog` from the environment and calls action methods to mutate it.
//

import Foundation
import Observation

@Observable
@MainActor
final class ModelManager {
    static let shared = ModelManager()

    private(set) var catalog: [ModelEntry]

    private let fluidDownloader: FluidAudioDownloader
    private let mlxDownloader: MLXModelDownloader
    private let whisperKitDownloader: WhisperKitModelDownloader
    private var tasks: [String: Task<Void, Never>] = [:]

    /// Fired after a download transitions to `.downloaded`. Used by
    /// DictationCoordinator to prewarm the freshly-installed model (any
    /// local backend) so the first dictation after install doesn't pay
    /// the cold model-load + first-inference specialization cost. See
    /// `Transcriber.prewarm()`.
    var onDownloadComplete: ((String) -> Void)?

    init() {
        let fluidDownloader = FluidAudioDownloader()
        let mlxDownloader = MLXModelDownloader()
        let whisperKitDownloader = WhisperKitModelDownloader()
        self.fluidDownloader = fluidDownloader
        self.mlxDownloader = mlxDownloader
        self.whisperKitDownloader = whisperKitDownloader
        self.catalog = Self.initialCatalog(
            fluidDownloader: fluidDownloader,
            mlxDownloader: mlxDownloader,
            whisperKitDownloader: whisperKitDownloader
        )
    }

    // MARK: - Catalog seeding

    private static func initialCatalog(
        fluidDownloader: FluidAudioDownloader,
        mlxDownloader: MLXModelDownloader,
        whisperKitDownloader: WhisperKitModelDownloader
    ) -> [ModelEntry] {
        let parakeetV3Status: ModelEntry.Status =
            fluidDownloader.isInstalled("parakeet-v3") ? .downloaded : .notDownloaded

        let nemotronUnifiedStatus: ModelEntry.Status =
            fluidDownloader.isInstalled(NemotronUnifiedTranscriber.modelId) ? .downloaded : .notDownloaded

        let parakeetV2Status: ModelEntry.Status =
            fluidDownloader.isInstalled("parakeet-v2") ? .downloaded : .notDownloaded

        let qwen06bStatus: ModelEntry.Status =
            mlxDownloader.isInstalled("qwen3-asr-0.6b") ? .downloaded : .notDownloaded

        let qwen17bStatus: ModelEntry.Status =
            mlxDownloader.isInstalled("qwen3-asr-1.7b") ? .downloaded : .notDownloaded

        let whisperLargeV3TurboStatus: ModelEntry.Status =
            whisperKitDownloader.isInstalled("whisper-large-v3-turbo") ? .downloaded : .notDownloaded

        let whisperDistilLargeV3Status: ModelEntry.Status =
            whisperKitDownloader.isInstalled("whisper-distil-large-v3") ? .downloaded : .notDownloaded

        let whisperSmallStatus: ModelEntry.Status =
            whisperKitDownloader.isInstalled("whisper-small") ? .downloaded : .notDownloaded

        let whisperTinyStatus: ModelEntry.Status =
            whisperKitDownloader.isInstalled("whisper-tiny") ? .downloaded : .notDownloaded

        return [
            ModelEntry(
                id: "parakeet-v3",
                name: "Nvidia Parakeet Tdt 0.6B V3",
                description: "Ultra-fast transcription powered by NVIDIA FastConformer. Optimized for conversational speech and voice commands.",
                badge: nil,
                accuracy: 5,
                speed: 5,
                size: "461 MB",
                language: "Multilingual",
                isLocal: true,
                isOnline: false,
                status: parakeetV3Status
            ),
            ModelEntry(
                id: NemotronUnifiedTranscriber.modelId,
                name: "Nvidia Nemotron Unified ASR 0.6B",
                description: "NVIDIA's newest multilingual FastConformer (25 European languages) with live preview. You can pin the language, so French stays French. Punctuation built in.",
                badge: nil,
                accuracy: 5,
                speed: 5,
                size: "1.2 GB",
                language: "25 languages",
                isLocal: true,
                isOnline: false,
                status: nemotronUnifiedStatus
            ),
            ModelEntry(
                id: "parakeet-v2",
                name: "Nvidia Parakeet Tdt 0.6B V2",
                description: "Ultra-fast English-only transcription powered by NVIDIA FastConformer V2. Optimized for English dictation and voice commands.",
                badge: nil,
                accuracy: 5,
                speed: 5,
                size: "451 MB",
                language: "English",
                isLocal: true,
                isOnline: false,
                status: parakeetV2Status
            ),
            ModelEntry(
                id: "whisper-large-v3-turbo",
                name: "OpenAI Whisper Large V3 Turbo",
                description: "OpenAI's fastest large Whisper model. Optimized for speed with near-large accuracy across 100+ languages.",
                badge: nil,
                accuracy: 5,
                speed: 3,
                size: "3.0 GB",
                language: "Multilingual",
                isLocal: true,
                isOnline: false,
                status: whisperLargeV3TurboStatus
            ),
            ModelEntry(
                id: "whisper-distil-large-v3",
                name: "OpenAI Whisper Distil Large V3",
                description: "Distilled Whisper model. Near-large accuracy at 5x faster speed. English only.",
                badge: nil,
                accuracy: 4,
                speed: 5,
                size: "1.4 GB",
                language: "English",
                isLocal: true,
                isOnline: false,
                status: whisperDistilLargeV3Status
            ),
            ModelEntry(
                id: "whisper-small",
                name: "OpenAI Whisper Small",
                description: "Compact multilingual Whisper model. Good balance of accuracy and size for everyday dictation.",
                badge: nil,
                accuracy: 3,
                speed: 4,
                size: "479 MB",
                language: "Multilingual",
                isLocal: true,
                isOnline: false,
                status: whisperSmallStatus
            ),
            ModelEntry(
                id: "whisper-tiny",
                name: "OpenAI Whisper Tiny",
                description: "Smallest Whisper model. Ultra-fast with minimal storage. Good for quick dictation and trying Whisper out.",
                badge: nil,
                accuracy: 2,
                speed: 5,
                size: "73 MB",
                language: "Multilingual",
                isLocal: true,
                isOnline: false,
                status: whisperTinyStatus
            ),
            ModelEntry(
                id: "qwen3-asr-0.6b",
                name: "Qwen3 ASR 0.6B",
                description: "Alibaba's lightweight multilingual ASR. 52 languages including Chinese, Japanese, Korean. Optimized for speed.",
                badge: nil,
                accuracy: 4,
                speed: 5,
                size: "969 MB",
                language: "Multilingual",
                isLocal: true,
                isOnline: false,
                status: qwen06bStatus
            ),
            ModelEntry(
                id: "qwen3-asr-1.7b",
                name: "Qwen3 ASR 1.7B",
                description: "Alibaba's high-accuracy multilingual ASR. 52 languages including Chinese, Japanese, Korean. Competitive with Whisper Large V3.",
                badge: nil,
                accuracy: 5,
                speed: 4,
                size: "2.3 GB",
                language: "Multilingual",
                isLocal: true,
                isOnline: false,
                status: qwen17bStatus
            ),
            ModelEntry(
                id: "openai-api",
                name: "OpenAI API",
                description: "OpenAI API for transcription. GPT-4o Transcribe is recommended.",
                badge: "Recommended",
                accuracy: 5,
                speed: 4,
                size: "$0.006/min",
                language: "Multilingual",
                isLocal: false,
                isOnline: true,
                status: .downloaded
            ),
            ModelEntry(
                id: "groq-api",
                name: "Groq API",
                description: "Groq API for transcription. Whisper Large v3 is recommended.",
                badge: nil,
                accuracy: 4,
                speed: 4,
                size: "$0.006/min",
                language: "Multilingual",
                isLocal: false,
                isOnline: true,
                status: .downloaded
            ),
        ]
    }
}

extension ModelManager {
    /// Starts a download for `id`. No-op if a download is already in
    /// flight for this id. Reports progress through `catalog[i].status`.
    func download(_ id: String) {
        guard tasks[id] == nil else { return }
        guard let index = catalog.firstIndex(where: { $0.id == id }) else { return }

        // Seed with no ETA so the UI flips to .downloading immediately even
        // before the disk poller has accumulated enough samples to estimate.
        catalog[index].status = .downloading(fraction: nil, eta: nil)

        let isMLX = MLXModelConfig.models[id] != nil
        let isWhisperKit = WhisperKitModelConfig.models[id] != nil

        // Progress and terminal status writes are gated on
        // `tasks[id] != nil` rather than `Task.isCancelled`: the
        // WhisperKit downloader forwards progress through fresh
        // unstructured Tasks, so `Task.isCancelled` inspected *those*
        // (never-cancelled) tasks and the guard was dead on that path —
        // a straggler tick could overwrite the `.paused`/`.downloaded`
        // terminal state and leave the card stuck in .downloading with
        // no Task driving it. `tasks[id]` is cleared in the same
        // synchronous main-actor stretch as the terminal write, so the
        // gate is airtight, and `remove()` clears it early to keep a
        // half-cancelled SDK call from resurrecting a deleted model.
        let task = Task { [weak self] in
            guard let self else { return }
            let terminal: ModelEntry.Status
            do {
                if isWhisperKit {
                    try await self.whisperKitDownloader.download(id) { [weak self] status in
                        guard let self, self.tasks[id] != nil else { return }
                        self.update(id: id, status: status)
                    }
                } else if isMLX {
                    try await self.mlxDownloader.download(id) { [weak self] status in
                        guard let self, self.tasks[id] != nil else { return }
                        self.update(id: id, status: status)
                    }
                } else {
                    try await self.fluidDownloader.download(id) { [weak self] status in
                        guard let self, self.tasks[id] != nil else { return }
                        self.update(id: id, status: status)
                    }
                }
                terminal = .downloaded
            } catch is CancellationError {
                terminal = .paused
            } catch let failure as WhisperKitModelDownloader.Failure {
                terminal = .error(message: failure.errorDescription ?? "Download failed.")
            } catch let failure as MLXModelDownloader.Failure {
                terminal = .error(message: failure.errorDescription ?? "Download failed.")
            } catch let failure as FluidAudioDownloader.Failure {
                terminal = .error(message: failure.errorDescription ?? "Download failed.")
            } catch {
                terminal = .error(message: error.localizedDescription)
            }

            if self.tasks[id] != nil {
                self.tasks[id] = nil
                self.update(id: id, status: terminal)
                if case .downloaded = terminal {
                    self.onDownloadComplete?(id)
                }
            }
        }
        tasks[id] = task
    }

    /// Cancels an in-flight download. The Task's catch handler maps
    /// `CancellationError` to `.paused(progress: lastSeen)`.
    func cancel(_ id: String) {
        tasks[id]?.cancel()
    }

    /// Deletes the on-disk model files for `id` and resets status to
    /// `.notDownloaded`. For MLX models this also removes the HuggingFace
    /// Hub staging cache so the next download is a true re-download.
    /// Throws if the deletion itself fails.
    func remove(_ id: String) throws {
        guard let index = catalog.firstIndex(where: { $0.id == id }) else { return }

        // Abort any in-flight download and deregister it *before*
        // deleting files. Deregistering means the unwinding task's
        // terminal write is skipped (see download()), so it can't
        // flip the freshly-deleted model back to .paused/.downloaded
        // or fire the prewarm hook on half-deleted files.
        if let task = tasks[id] {
            task.cancel()
            tasks[id] = nil
        }

        let fm = FileManager.default
        if WhisperKitModelConfig.models[id] != nil {
            if let dir = whisperKitDownloader.cacheDirectory(id), fm.fileExists(atPath: dir.path) {
                try fm.removeItem(at: dir)
            }
        } else if MLXModelConfig.models[id] != nil {
            for dir in [mlxDownloader.cacheDirectory(id), mlxDownloader.hubStagingDirectory(id)] {
                if let dir, fm.fileExists(atPath: dir.path) {
                    try fm.removeItem(at: dir)
                }
            }
        } else if let dir = fluidDownloader.cacheDirectory(id), fm.fileExists(atPath: dir.path) {
            try fm.removeItem(at: dir)
        }
        catalog[index].status = .notDownloaded
    }

    /// Returns true iff `catalog` has an entry with this id whose
    /// status is `.downloaded`. Used by DictationCoordinator's
    /// preflight check to fail fast before kicking the recorder.
    /// Unknown ids return false.
    func isInstalled(_ id: String) -> Bool {
        catalog.first(where: { $0.id == id })?.status == .downloaded
    }

    // MARK: - Internal helpers

    private func update(id: String, status: ModelEntry.Status) {
        guard let index = catalog.firstIndex(where: { $0.id == id }) else { return }
        catalog[index].status = status
    }
}
