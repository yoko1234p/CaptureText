import CoreGraphics
import DeskCore
import Foundation

public enum ImportedDocument {
    public static func pages(from data: Data, cancellation: RecognitionCancellation? = nil) throws -> ImportedPageSource
    {
        try ImportedPageSource(data: data, cancellation: cancellation)
    }
}

/// Retains the encoded PDF and page metadata, not an array of decoded page bitmaps.
/// The lock serializes access to the same CGPDFDocument when callers use different workers.
public final class ImportedPageSource: @unchecked Sendable {
    private let document: CGPDFDocument?
    private let original: CGImage?
    private let dimensions: [(Int, Int)]
    private let lock = NSLock()
    public var count: Int { dimensions.count }
    fileprivate init(data: Data, cancellation: RecognitionCancellation?) throws {
        guard !data.isEmpty, data.count <= 40_000_000 else { throw DeskError.invalid(L10n.text("匯入圖片或文件最多 40 MB。")) }
        try cancellation?.check()
        if !data.starts(with: Data("%PDF-".utf8)) {
            let image = try Recognition.image(data: data)
            original = image
            document = nil
            dimensions = [(image.width, image.height)]
            return
        }
        guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider),
            !pdf.isEncrypted, pdf.numberOfPages > 0, pdf.numberOfPages <= 20
        else { throw DeskError.invalid(L10n.text("掃描文件必須為未加密的 PDF，最多 20 頁。")) }
        var sizes: [(Int, Int)] = []
        var totalPixels = 0
        for number in 1...pdf.numberOfPages {
            try cancellation?.check()
            guard let page = pdf.page(at: number) else { throw DeskError.invalid(L10n.text("無法讀取掃描頁面。")) }
            let box = page.getBoxRect(.cropBox)
            guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else {
                throw DeskError.invalid(L10n.text("掃描頁面尺寸不正確。"))
            }
            let rotated = abs(page.rotationAngle) % 180 == 90
            let size = CGSize(width: rotated ? box.height : box.width, height: rotated ? box.width : box.height)
            let scale = min(2, 3000 / max(size.width, size.height))
            let width = max(1, Int(ceil(size.width * scale)))
            let height = max(1, Int(ceil(size.height * scale)))
            totalPixels += width * height
            guard totalPixels <= 40_000_000 else { throw DeskError.invalid(L10n.text("掃描文件尺寸過大；請分批匯入。")) }
            sizes.append((width, height))
        }
        document = pdf
        original = nil
        dimensions = sizes
    }
    public func image(at index: Int, cancellation: RecognitionCancellation? = nil) throws -> CGImage {
        try cancellation?.check()
        guard dimensions.indices.contains(index) else { throw DeskError.invalid(L10n.text("掃描頁碼不正確。")) }
        if let original { return original }
        lock.lock()
        defer { lock.unlock() }
        return try autoreleasepool {
            try cancellation?.check()
            guard let page = document?.page(at: index + 1) else { throw DeskError.invalid(L10n.text("無法讀取掃描頁面。")) }
            let (width, height) = dimensions[index]
            guard
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { throw DeskError.invalid(L10n.text("無法配置掃描頁面。")) }
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(rect)
            context.concatenate(page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            guard let image = context.makeImage() else { throw DeskError.invalid(L10n.text("無法解碼掃描頁面。")) }
            try cancellation?.check()
            return image
        }
    }
}
