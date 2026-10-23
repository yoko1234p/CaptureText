import CoreGraphics
import Foundation

public enum CapturePreview {
    /// Own a small buffer, so a cropped screenshot cannot keep the full display bitmap alive after OCR.
    public static func image(_ original: CGImage, maxPixels: Int = 800) -> CGImage? {
        guard original.width > 0, original.height > 0 else { return nil }
        let limit = max(32, min(1600, maxPixels))
        let scale = min(1, Double(limit) / Double(max(original.width, original.height)))
        let width = max(1, Int((Double(original.width) * scale).rounded()))
        let height = max(1, Int((Double(original.height) * scale).rounded()))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
