import AppKit
import CaptureCore
import XCTest

@testable import CaptureText

final class CapturePrecisionTests: XCTestCase {
    static func document(_ text: String = "original") -> OCRDocument {
        OCRDocument(
            blocks: [
                OCRBlock(
                    bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                    candidates: [OCRTextCandidate(text: text, score: 1)])
            ], singleLine: false, width: 80, height: 24)
    }
    static func image(gray: CGFloat = 1) -> CGImage {
        let context = CGContext(
            data: nil, width: 80, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 24))
        return context.makeImage()!
    }
    func testCandidateDeduplicationAndExplicitURLFormatting() {
        var result = OCRPrecisionResult(original: Self.document("https://example.test/?a=1 read more"))
        result.add(result.original.text, variant: .enlarged)
        result.add("", variant: .secondary)
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.original.text, "https://example.test/?a=1 read more")
        XCTAssertEqual(OCRReviewFormatting.urlSuggestion("https://example.test/?a=1 2"), "https://example.test/?a=12")
        XCTAssertNil(OCRReviewFormatting.urlSuggestion("read https://example.test"))
        XCTAssertNil(OCRReviewFormatting.urlSuggestion("https://example.test https://other.test"))
    }
    @MainActor func testThinAutomaticRecoveryRegionKeepsRecognizedURL() throws {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black,
        ]
        let text = "https://example.test/item/0?token=Z1O0a_b9Il2&src=pc_user" as NSString
        let size = text.size(withAttributes: attributes)
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width)) + 12,
            pixelsHigh: Int(ceil(size.height)) + 12, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh).fill()
        text.draw(at: NSPoint(x: 6, y: 6), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        let result = try Recognition.document(bitmap.cgImage!, language: .automatic)
        XCTAssertFalse(result.text.isEmpty)
    }
    func testSyntheticOrRegressingEvidenceCannotEnableAutomaticReplacement() {
        for (real, disjoint, regressions, proposed) in [
            (false, true, 0, 3), (true, false, 0, 3), (true, true, 1, 3), (true, true, 0, -1),
        ] {
            XCTAssertFalse(
                OCRGateEvidence(
                    independentSources: 40, corrected: 5, regressed: regressions,
                    baselineEdits: 10, proposedEdits: proposed, realScreens: real, disjointSources: disjoint
                ).permitsAutomaticReplacement)
        }
    }
    func testChangedSubtitlesOrScreenDimensionsRejectVideoFrame() {
        let first = OCRFrameFingerprint(Self.image())!
        let dark = OCRFrameFingerprint(Self.image(gray: 0))!
        XCTAssertFalse(
            OCRVideoPolicy.eligible(
                original: Self.document("first"), proposed: Self.document("second"), originalFrame: first,
                proposedFrame: first))
        XCTAssertFalse(
            OCRVideoPolicy.eligible(
                original: Self.document(), proposed: Self.document(), originalFrame: first, proposedFrame: dark))
        XCTAssertTrue(first.identical(to: first))
    }
    func testCancellationBeforeRecognitionDoesNotStartWork() {
        let cancellation = RecognitionCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(
            try OCRPrecision.recognize(
                Self.image(),
                options:
                    CaptureRecognitionOptions(kind: .text, language: .english, words: [], singleLine: false),
                cancellation: cancellation))
    }
    @MainActor func makeModel() -> CaptureModel {
        let domain = "CapturePrecisionTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        addTeardownBlock { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        let model = CaptureModel(defaults: defaults)
        model.sound = false
        model.feedback = false
        model.secondaryEnabled = false
        model.precisionOperation = { _, _, _ in OCRPrecisionResult(original: Self.document()) }
        return model
    }
    @MainActor func wait(_ model: CaptureModel) async {
        for _ in 0..<100 {
            if !model.busy { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Recognition did not complete")
    }
    @MainActor func testReviewDoesNotCopyUntilAcceptedAndConsumesOnlyOnce() async {
        let model = makeModel()
        var copies: [String] = []
        model.copyText = { copies.append($0) }
        model.append = true
        model.recognizePrecisely(Self.image())
        await wait(model)
        XCTAssertTrue(copies.isEmpty)
        model.reviewDraft = "corrected"
        model.acceptReview()
        model.acceptReview()
        XCTAssertEqual(copies, ["corrected"])
        model.recognizePrecisely(Self.image())
        await wait(model)
        model.acceptReview()
        XCTAssertEqual(copies, ["corrected", "corrected\noriginal"])
    }
    @MainActor func testRereadReplacesCaptureInAdditiveBuffer() async {
        let model = makeModel()
        var copies: [String] = []
        model.append = true
        model.copyText = { copies.append($0) }
        model.recognitionOperation = { _, _, _ in "first" }
        model.recognize(Self.image())
        await wait(model)
        model.recognitionOperation = { _, _, _ in "wrong" }
        model.recognize(Self.image())
        await wait(model)
        model.reread()
        await wait(model)
        XCTAssertEqual(model.reviewDraft, "wrong")
        XCTAssertEqual(model.review?.candidates.dropFirst().first?.variant, .repeated)
        model.reviewDraft = "right"
        model.acceptReview()
        XCTAssertEqual(copies, ["first", "first\nwrong", "first\nright"])
    }
    @MainActor func testCancelAndLateCompletionLeaveClipboardAndNewResultAlone() async {
        let model = makeModel()
        var copies: [String] = []
        model.copyText = { copies.append($0) }
        model.precisionOperation = { _, _, _ in
            try? await Task.sleep(for: .milliseconds(100))
            return OCRPrecisionResult(original: Self.document("stale"))
        }
        model.recognizePrecisely(Self.image())
        model.dismissReview()
        model.recognitionOperation = { _, _, _ in "new" }
        model.recognize(Self.image())
        await wait(model)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(copies, ["new"])
        XCTAssertEqual(model.text, "new")
        XCTAssertNil(model.review)
    }
    @MainActor func testClearAdditiveBufferInvalidatesPendingReview() async {
        let model = makeModel()
        var copies: [String] = []
        model.copyText = { copies.append($0) }
        model.append = true
        model.recognizePrecisely(Self.image())
        await wait(model)
        model.clearAdditiveBuffer()
        model.acceptReview()
        XCTAssertTrue(copies.isEmpty)
        XCTAssertNil(model.review)
    }
    @MainActor func testEditedResultIsNotReplacedByReread() async {
        let model = makeModel()
        model.copyText = { _ in }
        model.recognitionOperation = { _, _, _ in "raw" }
        model.recognize(Self.image())
        await wait(model)
        model.text = "my edit"
        model.reread()
        XCTAssertNil(model.review)
        XCTAssertEqual(model.text, "my edit")
    }
    func testRepeatedSecondaryWorkerExitDoesNotBlockAfterSuspension() async throws {
        let executable = FileManager.default.temporaryDirectory.appendingPathComponent(
            "capture-exit-" + UUID().uuidString)
        try Data("#!/bin/sh\nprintf '{\"text\":\"OK\"}' > \"$3\"\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: executable) }
        for _ in 0..<8 {
            let result = try await SecondaryOCRWorker.recognize(
                Self.image(), document: Self.document(), language: .english,
                executable: executable, cancellation: RecognitionCancellation(), timeout: .seconds(2))
            XCTAssertEqual(result, "OK")
        }
    }
    func testSecondaryWorkerTimeoutCleansUpPrivateImages() async throws {
        let root = FileManager.default.temporaryDirectory
        let executable = root.appendingPathComponent("capture-timeout-" + UUID().uuidString)
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: executable) }
        let existing = Set(
            try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("capture-ocr-") })
        let start = ContinuousClock.now
        do {
            _ = try await SecondaryOCRWorker.recognize(
                Self.image(), document: Self.document(), language: .english,
                executable: executable, cancellation: RecognitionCancellation(), timeout: .milliseconds(50))
            XCTFail("Timed-out worker returned a result")
        } catch { XCTAssertLessThan(start.duration(to: .now), .seconds(3)) }
        let remaining = Set(
            try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("capture-ocr-") })
        XCTAssertEqual(existing, remaining)
    }
    func testNativeDictionariesMatchPinnedModels() throws {
        for (model, count) in [(OCRModel.multilingual, 18710), (.english, 438), (.korean, 11947)] {
            let values = try JSONDecoder().decode([String].self, from: Data(contentsOf: model.dictionary))
            XCTAssertEqual(values.count, count)
            XCTAssertEqual(values.first, "")
            XCTAssertEqual(values.last, " ")
        }
    }
}
