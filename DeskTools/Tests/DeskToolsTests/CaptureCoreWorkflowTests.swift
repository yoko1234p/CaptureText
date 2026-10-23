import AppKit
import CaptureCore
import Carbon
import XCTest

@testable import CaptureText

final class CaptureCoreWorkflowTests: XCTestCase {
    func testChangingSettingsDuringRecognitionOnlyAffectsFollowingRequests() async throws {
        let domain = temporaryDefaults()
        defer { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        let gate = ControlledCaptureRecognition()
        let firstStarted = expectation(description: "first recognition starts")
        let firstCopied = expectation(description: "first recognition uses captured copy policy")
        let model = try await MainActor.run { () throws -> CaptureModel in
            let model = Self.makeModel(domain: domain)
            model.language = .english
            model.append = true
            model.autoCopy = true
            model.singleLine = true
            model.copyText = {
                XCTAssertEqual($0, "first")
                firstCopied.fulfill()
            }
            model.recognitionOperation = { _, options, cancellation in
                try await gate.run(options, cancellation: cancellation, started: firstStarted)
            }
            model.recognize(try Self.image(), singleLine: false)
            model.language = .japanese
            model.append = false
            model.autoCopy = false
            return model
        }
        await fulfillment(of: [firstStarted], timeout: 2)
        let firstOptions = await gate.options(at: 0)
        XCTAssertEqual(firstOptions.language, .english)
        XCTAssertFalse(firstOptions.singleLine, "An explicit capture mode overrides the preference for one request")
        await gate.complete(0, text: "first")
        await fulfillment(of: [firstCopied], timeout: 2)

        let nextStarted = expectation(description: "next recognition starts")
        try await MainActor.run {
            XCTAssertTrue(model.singleLine, "The one-time mode must not change the saved preference")
            model.copyText = { _ in XCTFail("The next request has auto-copy disabled") }
            model.recognitionOperation = { _, options, cancellation in
                try await gate.run(options, cancellation: cancellation, started: nextStarted)
            }
            model.recognize(try Self.image())
        }
        await fulfillment(of: [nextStarted], timeout: 2)
        let nextOptions = await gate.options(at: 1)
        XCTAssertEqual(nextOptions.language, .japanese)
        XCTAssertTrue(nextOptions.singleLine)
        await gate.complete(1, text: "standalone")
        await waitForIdle(model)
        await MainActor.run { XCTAssertEqual(model.text, "standalone") }

        let resumedStarted = expectation(description: "additive recognition resumes")
        let resumedCopied = expectation(description: "independent additive buffer survives standalone capture")
        try await MainActor.run {
            model.autoCopy = true
            model.append = true
            model.copyText = {
                XCTAssertEqual($0, "first\nresumed")
                resumedCopied.fulfill()
            }
            model.recognitionOperation = { _, options, cancellation in
                try await gate.run(options, cancellation: cancellation, started: resumedStarted)
            }
            model.recognize(try Self.image())
        }
        await fulfillment(of: [resumedStarted], timeout: 2)
        await gate.complete(2, text: "resumed")
        await fulfillment(of: [resumedCopied], timeout: 2)
    }

    func testCancellationSignalsRecognitionAndDiscardsLateDelivery() async throws {
        let domain = temporaryDefaults()
        defer { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        let gate = ControlledCaptureRecognition()
        let started = expectation(description: "recognition starts")
        let noCopy = expectation(description: "cancelled recognition must not copy")
        noCopy.isInverted = true
        let focusReturned = expectation(description: "Return focus after selection and on cancel")
        focusReturned.expectedFulfillmentCount = 2
        focusReturned.assertForOverFulfill = true
        let model = try await MainActor.run { () throws -> CaptureModel in
            let model = Self.makeModel(domain: domain)
            model.text = "previous review"
            model.append = true
            model.copyText = { _ in noCopy.fulfill() }
            model.showWindow = { XCTFail("Quiet cancellation must return to the source application") }
            model.restoreForegroundApplication = { _ in focusReturned.fulfill() }
            model.recognitionOperation = { _, options, cancellation in
                try await gate.run(options, cancellation: cancellation, started: started)
            }
            model.recognize(try Self.image(), quiet: true)
            return model
        }
        await fulfillment(of: [started], timeout: 2)
        await MainActor.run { model.cancel() }
        let cancelled = await gate.isCancelled(at: 0)
        XCTAssertTrue(cancelled)
        await gate.complete(0, text: "late text")
        await fulfillment(of: [noCopy, focusReturned], timeout: 0.15)
        await MainActor.run {
            XCTAssertEqual(model.text, "previous review")
            XCTAssertFalse(model.busy)
            XCTAssertFalse(model.failed)
            XCTAssertTrue(model.message.contains("已取消"))
        }
    }

    func testCancellationBeforeRecognitionStartsNeverInvokesOperation() async throws {
        let domain = temporaryDefaults()
        defer { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        let model = try await MainActor.run { () throws -> CaptureModel in
            let model = Self.makeModel(domain: domain)
            model.text = "previous review"
            model.recognitionOperation = { _, _, _ in
                XCTFail("A cancelled request must not begin recognition")
                return "obsolete"
            }
            model.copyText = { _ in XCTFail("A cancelled request must not copy") }
            model.recognize(try Self.image(), quiet: true)
            model.cancel(show: false)
            return model
        }
        try await Task.sleep(for: .milliseconds(150))
        await MainActor.run {
            XCTAssertFalse(model.busy)
            XCTAssertEqual(model.text, "previous review")
        }
    }

    func testNewRequestSuppressesOlderErrorAndKeepsLatestResult() async throws {
        let domain = temporaryDefaults()
        defer { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        let gate = ControlledCaptureRecognition()
        let oldStarted = expectation(description: "older recognition starts")
        let newStarted = expectation(description: "replacement recognition starts")
        let copied = expectation(description: "replacement recognition copies")
        copied.assertForOverFulfill = true
        let model = try await MainActor.run { () throws -> CaptureModel in
            let model = Self.makeModel(domain: domain)
            model.copyText = {
                XCTAssertEqual($0, "latest")
                copied.fulfill()
            }
            model.recognitionOperation = { _, options, cancellation in
                try await gate.run(options, cancellation: cancellation, started: oldStarted)
            }
            model.recognize(try Self.image())
            return model
        }
        await fulfillment(of: [oldStarted], timeout: 2)
        try await MainActor.run {
            model.recognitionOperation = { _, options, cancellation in
                try await gate.run(options, cancellation: cancellation, started: newStarted)
            }
            model.recognize(try Self.image(), barcode: true)
        }
        await fulfillment(of: [newStarted], timeout: 2)
        let cancelled = await gate.isCancelled(at: 0)
        let kind = await gate.options(at: 1).kind
        XCTAssertTrue(cancelled)
        XCTAssertEqual(kind, .barcodes)
        await gate.fail(0)
        await gate.complete(1, text: "latest")
        await fulfillment(of: [copied], timeout: 2)
        await MainActor.run {
            XCTAssertEqual(model.text, "latest")
            XCTAssertFalse(model.failed)
            XCTAssertFalse(model.busy)
        }
    }

    func testClearingAdditiveTextCancelsPendingAppendAndStartsFresh() async throws {
        let domain = temporaryDefaults()
        defer { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        let gate = ControlledCaptureRecognition()
        let firstStarted = expectation(description: "initial append starts")
        let firstCopied = expectation(description: "initial append copied")
        let model = try await MainActor.run { () throws -> CaptureModel in
            let model = Self.makeModel(domain: domain)
            model.append = true
            model.copyText = {
                XCTAssertEqual($0, "first")
                firstCopied.fulfill()
            }
            model.recognitionOperation = { _, options, cancellation in
                try await gate.run(options, cancellation: cancellation, started: firstStarted)
            }
            model.recognize(try Self.image())
            return model
        }
        await fulfillment(of: [firstStarted], timeout: 2)
        await gate.complete(0, text: "first")
        await fulfillment(of: [firstCopied], timeout: 2)
        let pendingStarted = expectation(description: "pending append starts")
        try await MainActor.run {
            model.copyText = { _ in XCTFail("The pending append must be discarded") }
            model.recognitionOperation = { _, options, cancellation in
                try await gate.run(options, cancellation: cancellation, started: pendingStarted)
            }
            model.recognize(try Self.image())
        }
        await fulfillment(of: [pendingStarted], timeout: 2)
        await MainActor.run { model.clearAdditiveBuffer() }
        let cancelled = await gate.isCancelled(at: 1)
        XCTAssertTrue(cancelled)
        await gate.complete(1, text: "discarded")
        let freshStarted = expectation(description: "fresh append starts")
        let freshCopied = expectation(description: "fresh append contains no cleared or pending text")
        try await MainActor.run {
            model.copyText = {
                XCTAssertEqual($0, "fresh")
                freshCopied.fulfill()
            }
            model.recognitionOperation = { _, options, cancellation in
                try await gate.run(options, cancellation: cancellation, started: freshStarted)
            }
            model.recognize(try Self.image())
        }
        await fulfillment(of: [freshStarted], timeout: 2)
        await gate.complete(2, text: "fresh")
        await fulfillment(of: [freshCopied], timeout: 2)
    }

    func testRecognitionFailurePreservesReviewAndClipboardDelivery() async throws {
        let domain = temporaryDefaults()
        defer { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        let gate = ControlledCaptureRecognition()
        let started = expectation(description: "failing recognition starts")
        let model = try await MainActor.run { () throws -> CaptureModel in
            let model = Self.makeModel(domain: domain)
            model.text = "previous result"
            model.copyText = { _ in XCTFail("Failed OCR must not change the clipboard") }
            model.recognitionOperation = { _, options, cancellation in
                try await gate.run(options, cancellation: cancellation, started: started)
            }
            model.recognize(try Self.image())
            return model
        }
        await fulfillment(of: [started], timeout: 2)
        await gate.fail(0)
        await waitForIdle(model)
        await MainActor.run {
            XCTAssertTrue(model.failed)
            XCTAssertEqual(model.text, "previous result")
            XCTAssertEqual(model.message, "Fixture recognition failure")
        }
    }

    func testFailedImageImportCancelsOlderRecognitionAndRetainsImportError() async throws {
        let domain = temporaryDefaults()
        defer { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        let gate = ControlledCaptureRecognition()
        let started = expectation(description: "earlier recognition starts")
        let noCopy = expectation(description: "failed image import must suppress earlier delivery")
        noCopy.isInverted = true
        let brokenImage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try Data().write(to: brokenImage)
        defer { try? FileManager.default.removeItem(at: brokenImage) }
        let model = try await MainActor.run { () throws -> CaptureModel in
            let model = Self.makeModel(domain: domain)
            model.text = "previous result"
            model.copyText = { _ in noCopy.fulfill() }
            model.recognitionOperation = { _, options, cancellation in
                try await gate.run(options, cancellation: cancellation, started: started)
            }
            model.recognize(try Self.image())
            return model
        }
        await fulfillment(of: [started], timeout: 2)
        let importError = await MainActor.run { () -> String in
            model.openImage(brokenImage)
            XCTAssertTrue(model.failed)
            XCTAssertFalse(model.busy)
            return model.message
        }
        let cancelled = await gate.isCancelled(at: 0)
        XCTAssertTrue(cancelled)
        await gate.complete(0, text: "obsolete")
        await fulfillment(of: [noCopy], timeout: 0.15)
        await MainActor.run {
            XCTAssertEqual(model.text, "previous result")
            XCTAssertEqual(model.message, importError)
            XCTAssertTrue(model.failed)
        }
    }

    func testAdditiveLimitCountsUTF8AndSeparatorWithoutMutatingOnOverflow() throws {
        var buffer = "中"
        XCTAssertThrowsError(try CaptureOutput.combine("文", buffer: &buffer, additive: true, byteLimit: 6))
        XCTAssertEqual(buffer, "中")
        XCTAssertEqual(try CaptureOutput.combine("文", buffer: &buffer, additive: true, byteLimit: 7), "中\n文")
        XCTAssertEqual(
            try CaptureOutput.combine("standalone", buffer: &buffer, additive: false, byteLimit: 7), "standalone")
        XCTAssertEqual(buffer, "中\n文")
    }

    func testPreCancelledVisionRequestsNeverBeginRecognition() throws {
        let cancellation = RecognitionCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try Recognition.text(Self.image(), language: .english, cancellation: cancellation)) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertThrowsError(try Recognition.barcodes(Self.image(), cancellation: cancellation)) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testShortcutConflictAndRegistrationFailureKeepWorkingBindings() async throws {
        let domain = temporaryDefaults()
        defer { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        await MainActor.run {
            let defaults = UserDefaults(suiteName: domain)!
            let store = CaptureShortcutStore(defaults: defaults)
            let original = store[.capture]
            let duplicate = CaptureShortcut(
                key: UInt32(kVK_ANSI_2), modifiers: UInt32(controlKey | shiftKey), keyLabel: "other label")
            XCTAssertFalse(store.update(.barcodes, to: duplicate))
            XCTAssertEqual(store[.capture], original)
            XCTAssertNil(store[.barcodes])
            let custom = CaptureShortcut(key: UInt32(kVK_ANSI_T), modifiers: UInt32(cmdKey | optionKey), keyLabel: "T")
            XCTAssertTrue(store.update(.capture, to: custom))
            let saved = defaults.data(forKey: "captureShortcuts")
            store.registerChange = { _, _ in false }
            let rejected = CaptureShortcut(
                key: UInt32(kVK_ANSI_X), modifiers: UInt32(cmdKey | controlKey), keyLabel: "X")
            XCTAssertFalse(store.update(.capture, to: rejected))
            XCTAssertEqual(store[.capture], custom)
            XCTAssertEqual(defaults.data(forKey: "captureShortcuts"), saved)
            XCTAssertEqual(CaptureShortcutStore(defaults: defaults)[.capture], custom)
            store.registerChange = { _, _ in true }
            XCTAssertTrue(store.update(.repeatSelection, to: nil))
            XCTAssertNil(CaptureShortcutStore(defaults: defaults)[.repeatSelection])
        }
    }

    func testExistingAlternativeShortcutMigratesWithoutChangingCaptureModes() async {
        let domain = temporaryDefaults()
        defer { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        UserDefaults(suiteName: domain)?.set(1, forKey: "shortcutChoice")
        await MainActor.run {
            let defaults = UserDefaults(suiteName: domain)!
            let store = CaptureShortcutStore(defaults: defaults)
            XCTAssertEqual(store[.capture]?.display, "⌃⌥T")
            XCTAssertEqual(store[.repeatSelection]?.display, "⌃⇧3")
            XCTAssertNil(store[.withLineBreaks])
            XCTAssertNil(store[.withoutLineBreaks])
        }
    }

    private func temporaryDefaults() -> String {
        let domain = "CaptureCoreWorkflowTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defaults.set(false, forKey: "feedback")
        defaults.set(false, forKey: "sound")
        defaults.set(false, forKey: "speechAfterCapture")
        defaults.set(true, forKey: "autoCopy")
        return domain
    }
    @MainActor private static func makeModel(domain: String) -> CaptureModel {
        let model = CaptureModel(defaults: UserDefaults(suiteName: domain)!)
        model.showWindow = {}
        model.hideWindow = {}
        model.restoreForegroundApplication = { _ in }
        return model
    }
    private static func image() throws -> CGImage {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }
    private func waitForIdle(_ model: CaptureModel) async {
        for _ in 0..<400 {
            if await MainActor.run(body: { !model.busy }) { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Recognition did not finish")
    }
}

private actor ControlledCaptureRecognition {
    struct Pending {
        let options: CaptureRecognitionOptions
        let cancellation: RecognitionCancellation
        let continuation: CheckedContinuation<String, Error>
    }
    private var requests: [Pending] = []
    func run(_ options: CaptureRecognitionOptions, cancellation: RecognitionCancellation, started: XCTestExpectation)
        async throws -> String
    {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(Pending(options: options, cancellation: cancellation, continuation: continuation))
            started.fulfill()
        }
    }
    func options(at index: Int) -> CaptureRecognitionOptions { requests[index].options }
    func isCancelled(at index: Int) -> Bool { requests[index].cancellation.isCancelled }
    func complete(_ index: Int, text: String) { requests[index].continuation.resume(returning: text) }
    func fail(_ index: Int) {
        requests[index].continuation.resume(
            throwing: NSError(
                domain: "CaptureFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture recognition failure"])
        )
    }
}
