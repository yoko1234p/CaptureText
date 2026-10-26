import CoreGraphics
import Foundation

public struct OCRFrameFingerprint: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]
    public let sharpness: Double
    public init?(_ image: CGImage) {
        let scale = min(1, 512 / Double(image.width), 128 / Double(image.height))
        let width = max(4, Int(Double(image.width) * scale))
        let height = max(4, Int(Double(image.height) * scale))
        self.width = width
        self.height = height
        var data = [UInt8](repeating: 0, count: width * height)
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        pixels = data
        var energy = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let edge = Double(
                    4 * Int(data[i]) - Int(data[i - 1]) - Int(data[i + 1]) - Int(data[i - width]) - Int(data[i + width])
                )
                energy += edge * edge
            }
        }
        sharpness = energy / Double((width - 2) * (height - 2))
    }
    public func stable(comparedTo original: OCRFrameFingerprint) -> Bool {
        guard width == original.width, height == original.height else { return false }
        let delta = zip(pixels, original.pixels).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) }
        return delta / Double(pixels.count) / 255 < 0.025
    }
    public func identical(to other: OCRFrameFingerprint) -> Bool {
        width == other.width && height == other.height && pixels == other.pixels
    }
}

public enum OCRVideoPolicy {
    /// A frame is eligible only when both the captured pixels and recognized text
    /// agree with the selected frame. Changed subtitles are never stitched.
    public static func eligible(
        original: OCRDocument, proposed: OCRDocument,
        originalFrame: OCRFrameFingerprint, proposedFrame: OCRFrameFingerprint
    ) -> Bool {
        original.width == proposed.width && original.height == proposed.height
            && original.text == proposed.text && proposedFrame.stable(comparedTo: originalFrame)
    }
}
