import CaptureONNX
import CoreGraphics
import DeskCore
import Foundation

public enum PaddleOCR {
    public static func recognize(
        _ image: CGImage, document: OCRDocument, language: OCRLanguage,
        directory: URL = OCRModelPack.directory, cancellation: RecognitionCancellation
    ) throws -> String {
        guard !document.blocks.isEmpty, document.blocks.count <= 12,
            image.width == document.width, image.height == document.height
        else {
            throw DeskError.invalid(L10n.text("第二引擎每次最多重讀 12 行，請縮小選區。"))
        }
        let model = OCRModel.choose(language: language, text: document.text)
        let runtime = directory.appendingPathComponent(OCRModelPack.runtimeName)
        let modelURL = directory.appendingPathComponent(model.filename)
        guard try OCRModelPack.fileHash(modelURL) == model.sha256,
            try OCRModelPack.fileHash(runtime) == OCRModelPack.runtimeLibraryHash
        else {
            throw DeskError.invalid(L10n.text("OCR 模型校驗失敗。"))
        }
        try cancellation.check()
        let dictionary = try JSONDecoder().decode([String].self, from: Data(contentsOf: model.dictionary))
        var error = [CChar](repeating: 0, count: 512)
        guard let session = ctocr_open(runtime.path, modelURL.path, &error, error.count) else {
            throw DeskError.invalid(L10n.text("無法載入第二引擎，原始結果已保留。"))
        }
        defer { ctocr_close(session) }
        var lines: [String] = []
        for block in document.blocks {
            try cancellation.check()
            let b = block.bounds
            guard b.minX.isFinite, b.minY.isFinite, b.width.isFinite, b.height.isFinite else {
                throw DeskError.invalid(L10n.text("文字範圍不正確。"))
            }
            let rect = CGRect(
                x: b.minX * Double(image.width), y: (1 - b.maxY) * Double(image.height),
                width: b.width * Double(image.width), height: b.height * Double(image.height)
            )
            .insetBy(dx: -2, dy: -2).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard !rect.isNull, rect.width >= 1, rect.height >= 1, let crop = image.cropping(to: rect) else {
                throw DeskError.invalid(L10n.text("文字範圍不正確。"))
            }
            var tensor = try prepare(crop)
            var indices = [Int32](repeating: 0, count: 4096)
            var count = 0
            guard
                ctocr_recognize(
                    session, &tensor.pixels, Int32(tensor.width), &indices, indices.count,
                    &count, &error, error.count) == 1
            else {
                throw DeskError.invalid(L10n.text("第二引擎辨識未完成，原始結果已保留。"))
            }
            try cancellation.check()
            var previous: Int32 = -1
            var line = ""
            for value in indices.prefix(count) {
                guard value >= 0, Int(value) < dictionary.count else {
                    throw DeskError.invalid(L10n.text("OCR 模型字典不符。"))
                }
                if value != 0, value != previous { line += dictionary[Int(value)] }
                previous = value
            }
            lines.append(line)
        }
        return lines.joined(separator: document.singleLine ? " " : "\n")
    }

    private static func prepare(_ image: CGImage) throws -> (pixels: [Float], width: Int) {
        let width = min(3200, max(320, Int(48 * Double(image.width) / Double(image.height))))
        let resizedWidth = min(width, Int(ceil(48 * Double(image.width) / Double(image.height))))
        var rgba = [UInt8](repeating: 255, count: resizedWidth * 48 * 4)
        let rendered = rgba.withUnsafeMutableBytes { storage -> Bool in
            guard
                let context = CGContext(
                    data: storage.baseAddress, width: resizedWidth, height: 48,
                    bitsPerComponent: 8, bytesPerRow: resizedWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: resizedWidth, height: 48))
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: resizedWidth, height: 48))
            return true
        }
        guard rendered else { throw DeskError.invalid(L10n.text("無法配置 OCR 圖片。")) }
        var pixels = [Float](repeating: 0, count: width * 48 * 3)
        for y in 0..<48 {
            for x in 0..<resizedWidth {
                let source = (y * resizedWidth + x) * 4
                let target = y * width + x
                for channel in 0..<3 {
                    pixels[channel * width * 48 + target] = Float(rgba[source + 2 - channel]) / 127.5 - 1
                }
            }
        }
        return (pixels, width)
    }
}

public struct OCRWorkerRequest: Codable {
    public let document: OCRDocument
    public let language: OCRLanguage
    public init(document: OCRDocument, language: OCRLanguage) {
        self.document = document
        self.language = language
    }
}
public struct OCRWorkerResponse: Codable {
    public let text: String?
    public let error: String?
    public init(text: String? = nil, error: String? = nil) {
        self.text = text
        self.error = error
    }
}
