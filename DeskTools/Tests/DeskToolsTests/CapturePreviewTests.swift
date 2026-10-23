import CaptureCore
import CoreGraphics
import XCTest

final class CapturePreviewTests: XCTestCase {
    func testLargeAndCroppedScreenshotsKeepOnlySmallPreviewBuffers() throws {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 4000, height: 3000, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let original = try XCTUnwrap(context.makeImage())
        let preview = try XCTUnwrap(CapturePreview.image(original))
        XCTAssertEqual(preview.width, 800)
        XCTAssertEqual(preview.height, 600)
        XCTAssertLessThan(preview.bytesPerRow * preview.height, 2_000_000)
        let crop = try XCTUnwrap(original.cropping(to: CGRect(x: 120, y: 100, width: 100, height: 80)))
        let small = try XCTUnwrap(CapturePreview.image(crop))
        XCTAssertEqual(small.width, 100)
        XCTAssertEqual(small.height, 80)
        XCTAssertLessThan(small.bytesPerRow * small.height, 40_000)
        XCTAssertEqual(original.width, 4000)
    }
}
