//
//  ModelMigrationTests.swift
//  oraTests
//
//  Covers the 0.7.0 model-lineup change: a stored Whisper selection
//  falls back to the default model, and SenseVoice's per-piece joining
//  of long recordings.
//

import Foundation
import Testing
@testable import ora

@MainActor
struct ModelMigrationTests {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "ora.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    @Test("a stored Whisper selection falls back to the default model and is persisted")
    func whisperSelectionFallsBack() {
        withDefaults { defaults in
            defaults.set("whisper-large-v3-turbo", forKey: "ora.selectedModelId")
            let prefs = Preferences(defaults: defaults)
            #expect(prefs.selectedModelId == Preferences.defaultModelId)
            #expect(defaults.string(forKey: "ora.selectedModelId") == Preferences.defaultModelId)
        }
    }

    @Test("a stored Qwen3-ASR selection falls back to the default model")
    func qwenSelectionFallsBack() {
        withDefaults { defaults in
            defaults.set("qwen3-asr-1.7b", forKey: "ora.selectedModelId")
            #expect(Preferences(defaults: defaults).selectedModelId == Preferences.defaultModelId)
        }
    }

    @Test("stored Parakeet v2/v3 selections move to Parakeet Ultra")
    func parakeetSelectionMigrates() {
        for old in ["parakeet-v2", "parakeet-v3"] {
            withDefaults { defaults in
                defaults.set(old, forKey: "ora.selectedModelId")
                #expect(Preferences(defaults: defaults).selectedModelId == "parakeet-ultra")
            }
        }
    }

    @Test("other stored selections are kept")
    func otherSelectionKept() {
        withDefaults { defaults in
            defaults.set("sensevoice-small", forKey: "ora.selectedModelId")
            #expect(Preferences(defaults: defaults).selectedModelId == "sensevoice-small")
        }
    }

    @Test("Nemotron Streaming language defaults to auto")
    func streamingLanguageDefault() {
        withDefaults { defaults in
            #expect(Preferences(defaults: defaults).nemotronStreamingLanguage == "auto")
        }
    }

    @Test("SenseVoice join: no space next to Chinese/Japanese, one space for Latin and Korean")
    func senseVoiceJoin() {
        #expect(SenseVoiceTranscriber.join(["今天天气很好，", "我们去公园。"]) == "今天天气很好，我们去公园。")
        #expect(SenseVoiceTranscriber.join(["Hello there.", "How are you?"]) == "Hello there. How are you?")
        #expect(SenseVoiceTranscriber.join(["안녕하세요.", " 반갑습니다."]) == "안녕하세요. 반갑습니다.")
        #expect(SenseVoiceTranscriber.join(["", "only", ""]) == "only")
    }

    @Test("Nemotron Streaming punctuation tidy-up")
    func nemotronPunctuation() {
        let tidy = NemotronStreamingTranscriber.tidyPunctuation
        #expect(tidy("今天下午三点, 我们开会, 讨论计划") == "今天下午三点，我们开会，讨论计划。")
        #expect(tidy("明日の午前十時です。 資料を確認して") == "明日の午前十時です。資料を確認して。")
        #expect(tidy("一共是1,000块钱, 好吗?") == "一共是1,000块钱，好吗？")
        #expect(tidy("회의가 있습니다. 메시지를 보내주세요") == "회의가 있습니다. 메시지를 보내주세요.")
        #expect(tidy("Please send me the report") == "Please send me the report.")
        #expect(tidy("Is it done?") == "Is it done?")
        #expect(tidy("我们10:30见") == "我们10:30见。")
        #expect(tidy("  ") == "")
    }
}
