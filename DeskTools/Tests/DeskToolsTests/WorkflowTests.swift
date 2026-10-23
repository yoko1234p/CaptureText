import AppKit
import CaptureCore
import Foundation
import XCTest

@testable import CaptureText

final class WorkflowTests: XCTestCase {
    func testQuietOCRCopiesWithoutOpeningResultWindow() async throws {
        let completion = expectation(description: "quiet OCR copies text")
        let model = try await MainActor.run { () throws -> CaptureModel in
            let model = CaptureModel()
            model.language = .english
            model.autoCopy = true
            model.append = false
            model.sound = false
            model.feedback = false
            model.speechAfterCapture = false
            model.showWindow = { XCTFail("Quiet capture must not open the result window") }
            model.copyText = { text in
                XCTAssertEqual(text, "Quiet capture 12345.")
                completion.fulfill()
            }
            let bitmap = try XCTUnwrap(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 1000, pixelsHigh: 200,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 1000, height: 200).fill()
            ("Quiet capture 12345." as NSString).draw(
                at: NSPoint(x: 30, y: 70),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 52), .foregroundColor: NSColor.black,
                ])
            NSGraphicsContext.restoreGraphicsState()
            model.recognize(try XCTUnwrap(bitmap.cgImage), quiet: true)
            return model
        }
        await fulfillment(of: [completion], timeout: 10)
        await MainActor.run {
            XCTAssertFalse(model.busy)
            XCTAssertFalse(model.failed)
        }
    }

    func testAdditiveCaptureHasIndependentBuffer() {
        var buffer = ""
        XCTAssertEqual(CaptureOutput.combine("first", buffer: &buffer, additive: true), "first")
        XCTAssertEqual(CaptureOutput.combine("second", buffer: &buffer, additive: true), "first\nsecond")
        XCTAssertEqual(CaptureOutput.combine("single", buffer: &buffer, additive: false), "single")
        XCTAssertEqual(buffer, "first\nsecond")
        buffer = ""
        XCTAssertEqual(CaptureOutput.combine("fresh", buffer: &buffer, additive: true), "fresh")
    }
}
