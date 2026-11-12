//
//  ModelEntry.swift
//  ora
//
//  Data type for a transcription model entry — shared by the catalog
//  (Models/ModelManager) and the UI (UI/Settings/ModelsPage).
//

import Foundation

struct ModelEntry: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let badge: String?
    let accuracy: Int
    let speed: Int
    let size: String
    let language: String
    let isLocal: Bool
    let isOnline: Bool
    var status: Status

    /// Whether this model is fast enough for the live-preview loop
    /// (periodic full-buffer re-transcription, spec §5.0). Parakeet —
    /// measured 0.13–0.56 s per round on ANE — and Nemotron Unified, the
    /// same 0.6B FastConformer class on the ANE (FluidAudio measures its
    /// 15 s offline encoder pass at ~15–26 ms on M5 Pro; not yet
    /// measured inside Ora's preview loop). Other local
    /// backends flip to true once their per-round latency is validated
    /// (spec Phase 3); cloud models stay false (would re-upload the
    /// whole buffer every second).
    var supportsLivePreview: Bool {
        switch id {
        case "parakeet-v2", "parakeet-v3", NemotronUnifiedTranscriber.modelId: true
        default: false
        }
    }

    /// Asset name for the provider's brand icon (OpenAI / NVIDIA / Groq).
    /// `nil` falls back to the card's generic SF Symbol.
    var brandIconAsset: String? {
        switch id {
        case "parakeet-v2", "parakeet-v3", NemotronUnifiedTranscriber.modelId: "BrandNvidia"
        case "openai-api": "BrandOpenAI"
        case "groq-api": "BrandGroq"
        case "qwen3-asr-0.6b", "qwen3-asr-1.7b": "BrandQwen"
        case _ where WhisperKitModelConfig.models[id] != nil: "BrandOpenAI"
        default: nil
        }
    }

    enum Status: Equatable {
        case downloaded
        case notDownloaded
        /// `fraction` is 0…1 (or `nil` before the first measurement).
        /// `eta` is `nil` until the downloader has accumulated enough samples
        /// to estimate a remaining time (typically the first ~4 seconds, or
        /// any time speed drops to 0).
        case downloading(fraction: Double?, eta: TimeInterval?)
        case paused
        case extracting
        case error(message: String)
    }
}
