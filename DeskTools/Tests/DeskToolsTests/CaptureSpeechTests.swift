import CaptureCore
import XCTest

@testable import CaptureText

final class CaptureSpeechTests: XCTestCase {
    private static let voices: [CaptureSpeechVoice] = [
        .init(identifier: "english-us", name: "English", language: "en-US"),
        .init(identifier: "english-gb", name: "British", language: "en-GB", quality: 2),
        .init(identifier: "cantonese", name: "廣東話", language: "yue-HK"),
        .init(identifier: "mandarin", name: "普通話", language: "zh-CN"),
        .init(identifier: "taiwan", name: "國語", language: "zh-TW"),
        .init(identifier: "japanese", name: "日本語", language: "ja-JP"),
        .init(identifier: "korean", name: "한국어", language: "ko-KR"),
        .init(identifier: "vietnamese", name: "Tiếng Việt", language: "vi-VN"),
    ]

    func testMixedLanguagesGetDistinctVoicesInsteadOfTheSystemDefault() throws {
        let input = "請擷取螢幕上的文字。\nPlease capture the screen text.\n画面に表示された文字を読み取ります。\n화면에 표시된 글자를 인식합니다."
        let plan = try CaptureSpeechPlanner.plan(text: input, language: .automatic, voices: Self.voices)
        XCTAssertEqual(plan.map(\.voiceID), ["cantonese", "english-gb", "japanese", "korean"])
        XCTAssertEqual(plan.map(\.text).joined(separator: "\n"), input)
    }

    func testSentenceLanguageDetectionWorksWithoutNewlines() throws {
        let plan = try CaptureSpeechPlanner.plan(
            text: "Please read the text on the screen. 画面に表示された文字を読み取ります。",
            language: .automatic, voices: Self.voices)
        XCTAssertEqual(plan.map(\.language), ["en-GB", "ja-JP"])
    }

    func testSelectedVoiceOverridesDetectionAndMissingSelectedVoiceIsActionable() throws {
        let plan = try CaptureSpeechPlanner.plan(
            text: "日本語を読みます。", language: .automatic, selectedVoiceID: "english-us", voices: Self.voices,
            detectLanguage: { _ in
                XCTFail("A manual voice does not need language detection")
                return nil
            })
        XCTAssertEqual(plan.map(\.voiceID), ["english-us"])
        XCTAssertThrowsError(
            try CaptureSpeechPlanner.plan(
                text: "日本語", language: .automatic, selectedVoiceID: "removed-voice", voices: Self.voices)
        ) { error in
            XCTAssertEqual(error as? CaptureSpeechError, .unavailableVoice("已選聲音"))
            XCTAssertTrue(error.localizedDescription.contains("設定"))
        }
    }

    func testExactRegionWinsAndRegionalFallbackDoesNotChangeLanguage() {
        XCTAssertEqual(CaptureSpeechPlanner.matchingVoice(for: "en_US", voices: Self.voices)?.identifier, "english-us")
        XCTAssertEqual(CaptureSpeechPlanner.matchingVoice(for: "en-AU", voices: Self.voices)?.identifier, "english-gb")
        XCTAssertNil(CaptureSpeechPlanner.matchingVoice(for: "mr-IN", voices: Self.voices))
        XCTAssertNil(CaptureSpeechPlanner.matchingVoice(for: "ars-SA", voices: Self.voices))
    }

    func testChineseScriptsCantoneseAndVisionVietnameseAliasesMatchInstalledIdentifiers() {
        XCTAssertEqual(CaptureSpeechPlanner.matchingVoice(for: "zh-Hant", voices: Self.voices)?.identifier, "cantonese")
        XCTAssertEqual(CaptureSpeechPlanner.matchingVoice(for: "zh-Hans", voices: Self.voices)?.identifier, "mandarin")
        XCTAssertEqual(CaptureSpeechPlanner.matchingVoice(for: "zh-TW", voices: Self.voices)?.identifier, "taiwan")
        XCTAssertEqual(
            CaptureSpeechPlanner.matchingVoice(for: "yue-Hans", voices: Self.voices)?.identifier, "cantonese")
        XCTAssertEqual(CaptureSpeechPlanner.matchingVoice(for: "vi-VT", voices: Self.voices)?.identifier, "vietnamese")
    }

    func testUnavailableDetectedLanguageStopsPlanningInsteadOfReadingItInEnglish() {
        XCTAssertThrowsError(
            try CaptureSpeechPlanner.plan(
                text: "स्क्रीन पर पाठ पढ़ें।", language: .automatic, voices: Self.voices, detectLanguage: { _ in "mr" })
        ) { error in
            XCTAssertEqual(error as? CaptureSpeechError, .unavailableVoice("mr"))
        }
    }

    func testNormalVoiceIsPreferredOverNoveltyAndHigherQualityWithinTheSameRegion() {
        let voices: [CaptureSpeechVoice] = [
            .init(identifier: "novelty", name: "Novelty", language: "en-US", quality: 3, isNovelty: true),
            .init(identifier: "basic", name: "Basic", language: "en-US"),
            .init(identifier: "enhanced", name: "Enhanced", language: "en-US", quality: 2),
        ]
        XCTAssertEqual(CaptureSpeechPlanner.matchingVoice(for: "en-US", voices: voices)?.identifier, "enhanced")
    }

    func testLongTextIsBoundedAndChunksPreserveCharacters() throws {
        let text = String(repeating: "A", count: 9001)
        let plan = try CaptureSpeechPlanner.plan(text: text, language: .english, voices: Self.voices)
        XCTAssertEqual(plan.map(\.text).joined(), text)
        XCTAssertTrue(plan.allSatisfy { $0.text.count <= 4000 })
        XCTAssertThrowsError(
            try CaptureSpeechPlanner.plan(
                text: String(repeating: "A", count: 100_001), language: .english, voices: Self.voices)
        ) { XCTAssertEqual($0 as? CaptureSpeechError, .tooMuchText) }
        XCTAssertThrowsError(
            try CaptureSpeechPlanner.plan(
                text: Array(repeating: "Hello world.", count: 129).joined(separator: "\n"), language: .english,
                voices: Self.voices)
        ) { XCTAssertEqual($0 as? CaptureSpeechError, .tooManySegments) }
    }

    func testToggleStopsWithoutPlanningOrQueueingAnotherUtterance() async throws {
        try await MainActor.run {
            let domain = "CaptureSpeechTests." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            defer { defaults.removePersistentDomain(forName: domain) }
            let playback = SpeechPlaybackFixture()
            var detectionCalls = 0
            let speech = CaptureSpeechController(
                defaults: defaults, voices: Self.voices,
                detectLanguage: { _ in
                    detectionCalls += 1
                    return "en"
                }, playback: playback)
            speech.toggle(text: "Please read this text.", language: .automatic)
            XCTAssertTrue(speech.isSpeaking)
            XCTAssertEqual(playback.plans.count, 1)
            XCTAssertEqual(detectionCalls, 1)
            speech.toggle(text: "Do not enqueue this text.", language: .automatic)
            XCTAssertFalse(speech.isSpeaking)
            XCTAssertEqual(playback.plans.count, 1)
            XCTAssertEqual(detectionCalls, 1)
            XCTAssertTrue(speech.status.contains("停止"))
        }
    }

    func testControllerCompletionPreferencesAndRateClampingWithoutPlayingAudio() async throws {
        try await MainActor.run {
            let domain = "CaptureSpeechTests." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            defer { defaults.removePersistentDomain(forName: domain) }
            defaults.set(true, forKey: "speechAfterCapture")
            let playback = SpeechPlaybackFixture()
            let speech = CaptureSpeechController(defaults: defaults, voices: Self.voices, playback: playback)
            speech.selectedVoiceID = "english-us"
            speech.rate = 9
            XCTAssertEqual(speech.rate, CaptureSpeechController.rateRange.upperBound)
            speech.speak(text: "Hello world.", language: .automatic)
            XCTAssertEqual(playback.plans.first?.first?.voiceID, "english-us")
            XCTAssertEqual(playback.rates.first, Float(CaptureSpeechController.rateRange.upperBound))
            XCTAssertTrue(speech.isSpeaking)
            playback.onCompletion?()
            XCTAssertFalse(speech.isSpeaking)
            XCTAssertTrue(speech.status.contains("完成"))
            let restored = CaptureSpeechController(
                defaults: defaults, voices: Self.voices, playback: SpeechPlaybackFixture())
            XCTAssertEqual(restored.selectedVoiceID, "english-us")
            XCTAssertEqual(restored.rate, CaptureSpeechController.rateRange.upperBound)
            XCTAssertTrue(defaults.bool(forKey: "speechAfterCapture"))
            speech.rate = .nan
            XCTAssertTrue(speech.rate.isFinite)
        }
    }

    func testControllerReportsMissingVoiceAndDoesNotQueueAudio() async throws {
        try await MainActor.run {
            let domain = "CaptureSpeechTests." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            defer { defaults.removePersistentDomain(forName: domain) }
            let playback = SpeechPlaybackFixture()
            let speech = CaptureSpeechController(
                defaults: defaults, voices: Self.voices, detectLanguage: { _ in "mr" }, playback: playback)
            speech.speak(text: "पाठ वाचा", language: .automatic)
            XCTAssertFalse(speech.isSpeaking)
            XCTAssertTrue(playback.plans.isEmpty)
            XCTAssertTrue(speech.status.contains("沒有可用"))
            XCTAssertTrue(speech.status.contains("設定"))
        }
    }
}

@MainActor private final class SpeechPlaybackFixture: CaptureSpeechPlayback {
    var onCompletion: (() -> Void)?
    var plans: [[CaptureSpeechSegment]] = []
    var rates: [Float] = []
    var stops = 0
    func speak(_ segments: [CaptureSpeechSegment], rate: Float) throws {
        plans.append(segments)
        rates.append(rate)
    }
    func stop() { stops += 1 }
}
