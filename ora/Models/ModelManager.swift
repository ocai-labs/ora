//
//  ModelManager.swift
//  ora
//
//  Source of truth for the local + API model catalog. Owns per-entry
//  status, download Tasks, and the FluidAudio adapter. UI reads
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
    private var tasks: [String: Task<Void, Never>] = [:]

    /// Fired after a download transitions to `.downloaded`. Used by
    /// DictationCoordinator to prewarm the freshly-installed model (any
    /// local backend) so the first dictation after install doesn't pay
    /// the cold model-load + first-inference specialization cost. See
    /// `Transcriber.prewarm()`.
    var onDownloadComplete: ((String) -> Void)?

    init() {
        let fluidDownloader = FluidAudioDownloader()
        self.fluidDownloader = fluidDownloader
        self.catalog = Self.initialCatalog(
            fluidDownloader: fluidDownloader
        )
    }

    // MARK: - Catalog seeding

    private static func initialCatalog(
        fluidDownloader: FluidAudioDownloader
    ) -> [ModelEntry] {
        let parakeetV3Status: ModelEntry.Status =
            fluidDownloader.isInstalled("parakeet-v3") ? .downloaded : .notDownloaded

        let nemotronUnifiedStatus: ModelEntry.Status =
            fluidDownloader.isInstalled(NemotronUnifiedTranscriber.modelId) ? .downloaded : .notDownloaded

        let nemotronStreamingStatus: ModelEntry.Status =
            fluidDownloader.isInstalled(NemotronStreamingTranscriber.modelId) ? .downloaded : .notDownloaded

        let senseVoiceStatus: ModelEntry.Status =
            fluidDownloader.isInstalled(SenseVoiceTranscriber.modelId) ? .downloaded : .notDownloaded

        let parakeetV2Status: ModelEntry.Status =
            fluidDownloader.isInstalled("parakeet-v2") ? .downloaded : .notDownloaded

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
                id: NemotronStreamingTranscriber.modelId,
                name: "Nvidia Nemotron 3.5 ASR Streaming 0.6B",
                description: "NVIDIA's multilingual model for Asian and European languages: Chinese, Japanese, Korean, Vietnamese, Hindi and 30 more. Live preview, pinnable language, punctuation built in.",
                badge: nil,
                accuracy: 4,
                speed: 5,
                size: "665 MB",
                language: "~40 languages",
                isLocal: true,
                isOnline: false,
                status: nemotronStreamingStatus
            ),
            ModelEntry(
                id: SenseVoiceTranscriber.modelId,
                name: "SenseVoice Small",
                description: "Alibaba FunAudioLLM's Chinese-first model with live preview. Very fast and accurate for Mandarin and Cantonese; also English, Japanese and Korean, detected automatically.",
                badge: nil,
                accuracy: 5,
                speed: 5,
                size: "240 MB",
                language: "Chinese, Cantonese, English, Japanese, Korean",
                isLocal: true,
                isOnline: false,
                status: senseVoiceStatus
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


        // Progress and terminal status writes are gated on
        // `tasks[id] != nil` rather than `Task.isCancelled`: progress
        // callbacks can arrive on unstructured Tasks whose own
        // `isCancelled` never flips, so a straggler tick could overwrite
        // the `.paused`/`.downloaded` terminal state and leave the card
        // stuck in .downloading with no Task driving it. `tasks[id]` is
        // cleared in the same
        // synchronous main-actor stretch as the terminal write, so the
        // gate is airtight, and `remove()` clears it early to keep a
        // half-cancelled SDK call from resurrecting a deleted model.
        let task = Task { [weak self] in
            guard let self else { return }
            let terminal: ModelEntry.Status
            do {
                try await self.fluidDownloader.download(id) { [weak self] status in
                    guard let self, self.tasks[id] != nil else { return }
                    self.update(id: id, status: status)
                }
                terminal = .downloaded
            } catch is CancellationError {
                terminal = .paused
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
    /// `.notDownloaded`. Throws if the deletion itself fails.
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
        if let dir = fluidDownloader.cacheDirectory(id), fm.fileExists(atPath: dir.path) {
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
