import CaptureCore
import XCTest

final class CaptureLanguageTests: XCTestCase {
    func testManualChoicesCoverTheRecordedMacOS27AccurateLanguages() {
        let recordedCodes = [
            "en-US", "fr-FR", "it-IT", "de-DE", "es-ES", "pt-BR", "zh-Hans", "zh-Hant", "yue-Hans", "yue-Hant",
            "ko-KR", "ja-JP", "ru-RU", "uk-UA", "th-TH", "vi-VT", "ar-SA", "ars-SA", "tr-TR", "id-ID", "cs-CZ",
            "da-DK", "nl-NL", "no-NO", "nn-NO", "nb-NO", "ms-MY", "pl-PL", "ro-RO", "sv-SE", "fi-FI", "hi-IN",
            "mr-IN",
        ]
        let manual = OCRLanguage.allCases.filter { $0 != .automatic }
        let represented = Set(manual.flatMap(\.primaryCodes))
        XCTAssertTrue(Set(recordedCodes).isSubset(of: represented))
        for code in recordedCodes {
            XCTAssertTrue(manual.contains { $0.isSupported(by: [code]) }, "No manual choice for \(code)")
        }
    }

    func testEnglishFallbackDoesNotAdvertiseAnUnavailableScript() {
        XCTAssertFalse(OCRLanguage.arabic.isSupported(by: ["en-US"]))
        XCTAssertFalse(OCRLanguage.korean.isSupported(by: ["en-US", "fr-FR"]))
        XCTAssertTrue(OCRLanguage.english.isSupported(by: ["en-US"]))
    }

    func testAutomaticIncludesNewSystemLanguagesOnceAndKeepsCommonLanguagesFirst() {
        XCTAssertEqual(
            OCRLanguage.automatic.recognitionCodes(supported: ["ar-SA", "en-US", "zh-Hant", "ar-SA", "mr-IN"]),
            ["zh-Hant", "en-US", "ar-SA", "mr-IN"])
    }

    func testManualRegionalVariantsRemainAvailableWithEnglishInMixedText() {
        XCTAssertTrue(OCRLanguage.norwegian.isSupported(by: ["nn-NO", "en-US"]))
        XCTAssertEqual(OCRLanguage.norwegian.recognitionCodes(supported: ["en-US", "nn-NO"]), ["nn-NO", "en-US"])
        XCTAssertEqual(OCRLanguage.vietnamese.recognitionCodes(supported: ["vi-VT", "en-US"]), ["vi-VT", "en-US"])
        XCTAssertTrue(OCRLanguage.traditionalCantonese.isSupported(by: ["yue-Hant"]))
    }
}
