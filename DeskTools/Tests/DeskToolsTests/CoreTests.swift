import AppKit
import CoreImage
import Darwin
import DeskCore
import Vision
import XCTest

@testable import CaptureCore

final class GeometryTests: XCTestCase {
    func testRetinaCropFlipsYAxis() {
        XCTAssertEqual(
            SelectionGeometry.pixelRect(
                selection: CGRect(x: 10, y: 20, width: 100, height: 50),
                bounds: CGRect(x: 0, y: 0, width: 800, height: 600), imageWidth: 1600, imageHeight: 1200),
            CGRect(x: 20, y: 1060, width: 200, height: 100))
    }
    func testNegativeScreenOriginAndMixedScale() {
        XCTAssertEqual(
            SelectionGeometry.pixelRect(
                selection: CGRect(x: -1800, y: 100, width: 200, height: 150),
                bounds: CGRect(x: -1920, y: -200, width: 1920, height: 1080), imageWidth: 1920, imageHeight: 1080),
            CGRect(x: 120, y: 630, width: 200, height: 150))
    }
    func testClampsSelectionToScreen() {
        XCTAssertEqual(
            SelectionGeometry.pixelRect(
                selection: CGRect(x: -20, y: 90, width: 100, height: 50),
                bounds: CGRect(x: 0, y: 0, width: 100, height: 100), imageWidth: 200, imageHeight: 200),
            CGRect(x: 0, y: 0, width: 160, height: 20))
    }
    func testTinyAndOutsideSelectionsRejected() {
        for rect in [CGRect(x: 1, y: 1, width: 1, height: 1), CGRect(x: 200, y: 0, width: 10, height: 10)] {
            XCTAssertNil(
                SelectionGeometry.pixelRect(
                    selection: rect, bounds: CGRect(x: 0, y: 0, width: 100, height: 100), imageWidth: 200,
                    imageHeight: 200))
        }
    }

    func testCropPaddingIncludesNearbyPunctuationAndStaysOnScreen() {
        XCTAssertEqual(
            SelectionGeometry.pixelRect(
                selection: CGRect(x: 20, y: 10, width: 50, height: 10),
                bounds: CGRect(x: 0, y: 0, width: 100, height: 40),
                imageWidth: 200, imageHeight: 80, paddingPoints: 4),
            CGRect(x: 32, y: 32, width: 116, height: 36))
        XCTAssertEqual(
            SelectionGeometry.pixelRect(
                selection: CGRect(x: 0, y: 0, width: 20, height: 10),
                bounds: CGRect(x: 0, y: 0, width: 100, height: 40),
                imageWidth: 200, imageHeight: 80, paddingPoints: 4),
            CGRect(x: 0, y: 52, width: 48, height: 28))
    }
}

final class RecognitionTests: XCTestCase {
    func testRecognitionRetriesOnCPUAfterVisionFailure() async throws {
        let image = try await MainActor.run { () throws -> CGImage in
            let bitmap = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 160, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 900, height: 160).fill()
            ("Hello OCR 123" as NSString).draw(
                at: NSPoint(x: 30, y: 55),
                withAttributes: [.font: NSFont.systemFont(ofSize: 52), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState()
            return try XCTUnwrap(bitmap.cgImage)
        }
        var attempts = 0
        let result = try Recognition.textObservations(
            image, language: .english, words: [], cancellation: RecognitionCancellation()) { request in
                attempts += 1
                if attempts == 1 { throw NSError(domain: "fixture.vision", code: 13) }
                let stages = try request.supportedComputeStageDevices
                XCTAssertFalse(stages.isEmpty)
                for stage in stages.keys {
                    guard let selected = request.computeDevice(for: stage), case .cpu = selected else {
                        XCTFail("Retry must use an advertised CPU device for every stage")
                        return
                    }
                }
                try VNImageRequestHandler(cgImage: image).perform([request])
            }
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(result.compactMap { $0.topCandidates(1).first?.string }.joined().contains("Hello OCR"))
    }

    func testCancellationAfterVisionFailurePreventsRetry() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let cancellation = RecognitionCancellation()
        var attempts = 0
        XCTAssertThrowsError(try Recognition.textObservations(
            image, language: .english, words: [], cancellation: cancellation) { _ in
                attempts += 1
                cancellation.cancel()
                throw NSError(domain: "fixture.vision", code: 13)
            }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(attempts, 1)
    }

    func testRawURLFragmentsPreserveSpacesAndMissingPunctuation() {
        let fragments = ["https://example.com/explore/123?xsec_token=A B", "u_12&xsec_source=pc_user"]
        XCTAssertEqual(
            RecognizedTextLayout.join(fragments, singleLine: false),
            fragments.joined(separator: "\n"))
        XCTAssertEqual(
            RecognizedTextLayout.join(["https//example.com/a?b=1 2"], singleLine: false),
            "https//example.com/a?b=1 2")
    }

    func testURLCleanupLeavesOtherTextAndSeparateLinesAlone() {
        let prose = ["https://example.com/path?x=1 read more"]
        XCTAssertEqual(RecognizedTextLayout.join(prose, singleLine: false), prose[0])
        let separateLines = ["https://example.com/a?b=1", "Read more"]
        XCTAssertEqual(
            RecognizedTextLayout.join(separateLines, singleLine: false),
            separateLines.joined(separator: "\n"))
    }

    func testEnglishJapaneseAndTraditionalChineseOCR() async throws {
        for (language, expected) in [
            (OCRLanguage.english, "Hello OCR. Invoice 12345."),
            (.japanese, "今日は図書館で日本語を勉強します。"),
            (.traditionalChinese, "今天下午三點到圖書館學習。"),
        ] {
            let image = try await MainActor.run { () throws -> CGImage in
                let bitmap = try XCTUnwrap(
                    NSBitmapImageRep(
                        bitmapDataPlanes: nil, pixelsWide: 1800, pixelsHigh: 240,
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                NSColor.white.setFill()
                NSRect(x: 0, y: 0, width: 1800, height: 240).fill()
                (expected as NSString).draw(
                    at: NSPoint(x: 50, y: 80),
                    withAttributes: [
                        .font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black,
                    ])
                NSGraphicsContext.restoreGraphicsState()
                return try XCTUnwrap(bitmap.cgImage)
            }
            XCTAssertEqual(
                try Recognition.text(image, language: language).filter { !$0.isWhitespace },
                expected.filter { !$0.isWhitespace })
        }
    }
}
