import AppKit
import CaptureCore
import Vision
import XCTest

@testable import CaptureText

final class CaptureImportTests: XCTestCase {
    func testAutomaticLanguagePolicyIncludesEverySupportedLanguageWithoutDuplicates() throws {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = try request.supportedRecognitionLanguages()
        let automatic = OCRLanguage.automatic.recognitionCodes(supported: supported)
        XCTAssertEqual(Set(automatic), Set(supported))
        XCTAssertEqual(automatic.count, Set(automatic).count)
        XCTAssertTrue(automatic.contains("ko-KR"))
        XCTAssertTrue(automatic.contains("fr-FR"))
        XCTAssertEqual(OCRLanguage.korean.recognitionCodes(supported: supported), ["ko-KR", "en-US"])
        XCTAssertEqual(OCRLanguage.english.recognitionCodes(supported: supported), ["en-US"])
        XCTAssertEqual(OCRLanguage.automatic.recognitionCodes(supported: ["en-US"]), ["en-US"])
    }

    func testAutomaticOCRReadsMixedChineseJapaneseKoreanAndFrench() async throws {
        let expected = [
            "今天下午三點到圖書館學習。", "今日は図書館で日本語を勉強します。",
            "오늘 오후 세 시에 도서관에서 만나요.", "Bonjour, merci beaucoup.",
        ]
        let image = try await MainActor.run { try Self.image(lines: expected) }
        let result = try Recognition.text(image, language: .automatic)
        XCTAssertEqual(Self.withoutSpaces(result), Self.withoutSpaces(expected.joined(separator: "\n")))
        let korean = try await MainActor.run { try Self.image(lines: [expected[2]]) }
        XCTAssertEqual(
            Self.withoutSpaces(try Recognition.text(korean, language: .korean)), Self.withoutSpaces(expected[2]))
    }

    func testPhotoAndMultiPageScanDecodeInOrderAndRejectInvalidPayloads() async throws {
        let image = try await MainActor.run { try Self.image(lines: ["Phone photo 123."]) }
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        XCTAssertEqual(try ImportedDocument.pages(from: data).count, 1)
        let pdf = try await MainActor.run { try Self.pdf(pages: ["Page one.", "Page two."]) }
        let pages = try ImportedDocument.pages(from: pdf)
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(try Recognition.text(try pages.image(at: 0), language: .english), "Page one.")
        XCTAssertEqual(try Recognition.text(try pages.image(at: 1), language: .english), "Page two.")
        XCTAssertThrowsError(try ImportedDocument.pages(from: Data()))
        XCTAssertThrowsError(try ImportedDocument.pages(from: Data("%PDF-broken".utf8)))
        XCTAssertThrowsError(try ImportedDocument.pages(from: Data("not an image".utf8)))
        let tooManyPages = try await MainActor.run { try Self.pdf(pages: Array(repeating: "", count: 21)) }
        XCTAssertThrowsError(try ImportedDocument.pages(from: tooManyPages))
        let cancellation = RecognitionCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try ImportedDocument.pages(from: pdf, cancellation: cancellation)) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testScanSkipsBlankPageAndCopiesCombinedResultOnlyOnce() async throws {
        let domain = "ScanWorkflowTests." + UUID().uuidString
        defer { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        let copied = expectation(description: "Combined pages copied once")
        copied.assertForOverFulfill = true
        let pdf = try await MainActor.run { try Self.pdf(pages: ["Page one.", "", "Page three."]) }
        let model = await MainActor.run {
            let model = Self.model(domain: domain)
            model.autoCopy = true
            model.copyText = { text in
                XCTAssertEqual(text, "Page one.\n\nPage three.")
                copied.fulfill()
            }
            model.importDocument(pdf)
            return model
        }
        await fulfillment(of: [copied], timeout: 15)
        await MainActor.run {
            XCTAssertFalse(model.busy)
            XCTAssertFalse(model.failed)
            XCTAssertTrue(model.message.contains("3 頁"))
        }
    }

    func testContinuityReceiverUsesSuppliedPasteboardAndPreservesSystemClipboard() async throws {
        let domain = "ContinuityWorkflowTests." + UUID().uuidString
        defer { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        let image = try await MainActor.run { try Self.image(lines: ["Phone photo 123."]) }
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let clipboard = await MainActor.run { NSPasteboard.general.changeCount }
        let model = await MainActor.run {
            let model = Self.model(domain: domain)
            let receiver = CaptureImportController(model: model)
            XCTAssertTrue(
                (receiver.validRequestor(forSendType: nil, returnType: .png) as? CaptureImportController) === receiver)
            XCTAssertTrue(
                (receiver.validRequestor(forSendType: nil, returnType: .pdf) as? CaptureImportController) === receiver)
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            board.setString("unrelated plain text", forType: .string)
            XCTAssertFalse(receiver.readSelection(from: board))
            board.clearContents()
            board.setData(data, forType: .png)
            XCTAssertTrue(receiver.readSelection(from: board))
            return model
        }
        await waitForIdle(model)
        await MainActor.run {
            XCTAssertEqual(model.text, "Phone photo 123.")
            XCTAssertFalse(model.failed)
            XCTAssertEqual(NSPasteboard.general.changeCount, clipboard)
        }
    }

    func testCancelledScanNeverReplacesPreviousText() async throws {
        let domain = "CancelledScanTests." + UUID().uuidString
        defer { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        let pdf = try await MainActor.run { try Self.pdf(pages: ["Cancelled page."]) }
        let model = await MainActor.run {
            let model = Self.model(domain: domain)
            model.text = "previous result"
            model.copyText = { _ in XCTFail("Cancelled scan must not copy") }
            model.importDocument(pdf)
            model.cancel(show: false)
            return model
        }
        try await Task.sleep(for: .milliseconds(150))
        await MainActor.run {
            XCTAssertFalse(model.busy)
            XCTAssertEqual(model.text, "previous result")
        }
    }

    private static func withoutSpaces(_ text: String) -> String { text.filter { !$0.isWhitespace } }
    @MainActor private static func model(domain: String) -> CaptureModel {
        let defaults = UserDefaults(suiteName: domain)!
        defaults.set(false, forKey: "autoCopy")
        defaults.set(false, forKey: "feedback")
        defaults.set(false, forKey: "sound")
        let model = CaptureModel(defaults: defaults)
        model.language = .english
        model.showWindow = {}
        model.copyText = { _ in XCTFail("Unexpected clipboard write") }
        return model
    }
    @MainActor private static func image(lines: [String]) throws -> CGImage {
        let height = max(240, lines.count * 130)
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2400, pixelsHigh: height, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 2400, height: height).fill()
        for (index, line) in lines.enumerated() {
            (line as NSString).draw(
                at: NSPoint(x: 40, y: height - 110 - index * 130),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black,
                ])
        }
        return try XCTUnwrap(bitmap.cgImage)
    }
    @MainActor private static func pdf(pages: [String]) throws -> Data {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        var media = CGRect(x: 0, y: 0, width: 600, height: 180)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &media, nil))
        for text in pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(media)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (text as NSString).draw(
                at: NSPoint(x: 30, y: 60),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black,
                ])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
    private func waitForIdle(_ model: CaptureModel) async {
        for _ in 0..<300 {
            if await MainActor.run(body: { !model.busy }) { return }
            try? await Task.sleep(for: .milliseconds(30))
        }
        XCTFail("Import did not finish")
    }
}
