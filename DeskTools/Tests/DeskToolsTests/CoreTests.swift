import AppKit
import CaptureCore
import CoreImage
import Darwin
import DeskCore
import Vision
import XCTest

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
}

final class RecognitionTests: XCTestCase {
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
