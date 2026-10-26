import CoreGraphics
import DeskCore
import Foundation

public struct OCRTextCandidate: Codable, Equatable, Sendable {
    public let text: String
    public let score: Float
    public init(text: String, score: Float) {
        self.text = text
        self.score = score
    }
}

public struct OCRBlock: Codable, Sendable {
    public let bounds: CGRect
    public let candidates: [OCRTextCandidate]
    public init(bounds: CGRect, candidates: [OCRTextCandidate]) {
        self.bounds = bounds
        self.candidates = candidates
    }
}

public struct OCRDocument: Codable, Sendable {
    public let blocks: [OCRBlock]
    public let singleLine: Bool
    public let width: Int
    public let height: Int
    public var text: String {
        RecognizedTextLayout.join(blocks.compactMap { $0.candidates.first?.text }, singleLine: singleLine)
    }
    public var smallestTextHeight: Double { blocks.map { $0.bounds.height * Double(height) }.min() ?? 0 }
    public var needsReview: Bool {
        smallestTextHeight < 14 || blocks.contains { ($0.candidates.first?.score ?? 0) < 0.4 }
    }
    public init(blocks: [OCRBlock], singleLine: Bool, width: Int, height: Int) {
        self.blocks = blocks
        self.singleLine = singleLine
        self.width = width
        self.height = height
    }
}

public enum OCRVariant: String, Codable, Sendable {
    case original, repeated, literal, enlarged, secondary, urlFormatting, video
    public var title: String {
        switch self {
        case .original: return L10n.text("原始辨識")
        case .repeated: return L10n.text("再次辨識")
        case .literal: return L10n.text("原樣重讀")
        case .enlarged: return L10n.text("細字放大重讀")
        case .secondary: return L10n.text("第二引擎")
        case .urlFormatting: return L10n.text("網址排版建議")
        case .video: return L10n.text("影片清晰畫面")
        }
    }
}

public struct OCRReviewCandidate: Identifiable, Sendable {
    public let id: UUID
    public let variant: OCRVariant
    public let text: String
    public init(variant: OCRVariant, text: String) {
        id = UUID()
        self.variant = variant
        self.text = text
    }
}

public struct OCRPrecisionResult: Sendable {
    public let original: OCRDocument
    public var candidates: [OCRReviewCandidate]
    public var notices: [String]
    public init(original: OCRDocument) {
        self.original = original
        candidates = [OCRReviewCandidate(variant: .original, text: original.text)]
        notices = []
    }
    public mutating func add(_ text: String, variant: OCRVariant) {
        guard candidates.count < 12, !text.isEmpty, text.utf8.count <= 1_000_000,
            !candidates.contains(where: { $0.text == text })
        else { return }
        candidates.append(OCRReviewCandidate(variant: variant, text: text))
    }
}

public enum OCRPrecision {
    /// Bounded, serial passes. Cancellation owns one request at a time.
    public static func recognize(
        _ image: CGImage, options: CaptureRecognitionOptions, baseline: OCRDocument? = nil,
        cancellation: RecognitionCancellation
    ) throws -> OCRPrecisionResult {
        try cancellation.check()
        let original: OCRDocument
        if let baseline {
            original = baseline
        } else {
            do {
                original = try Recognition.document(
                    image, language: options.language, words: options.words,
                    singleLine: options.singleLine, cancellation: cancellation)
            } catch RecognitionTextError.noText {
                original = OCRDocument(
                    blocks: [], singleLine: options.singleLine, width: image.width, height: image.height)
            }
        }
        var result = OCRPrecisionResult(original: original)
        do {
            let literal = try Recognition.document(
                image, language: options.language, words: options.words,
                singleLine: options.singleLine, correction: false, cancellation: cancellation)
            result.add(literal.text, variant: .literal)
        } catch {
            try cancellation.check()
            result.notices.append(L10n.text("原樣重讀未完成，保留原始結果。"))
        }
        if original.smallestTextHeight < 24, let enlarged = OCRImageBuffer.copy(image, scale: 2) {
            do {
                try cancellation.check()
                let document = try Recognition.document(
                    enlarged, language: options.language, words: options.words,
                    singleLine: options.singleLine, cancellation: cancellation)
                result.add(document.text, variant: .enlarged)
            } catch {
                try cancellation.check()
                result.notices.append(L10n.text("放大重讀未完成，保留原始結果。"))
            }
        }
        try cancellation.check()
        guard result.candidates.contains(where: { !$0.text.isEmpty }) else { throw RecognitionTextError.noText }
        return result
    }
}

public enum OCRReviewFormatting {
    /// An explicit user action only; never use this as an OCR accuracy signal.
    public static func urlSuggestion(_ raw: String) -> String? {
        guard raw.utf8.count <= 8192 else { return nil }
        let compact = raw.filter { !$0.isWhitespace }
        guard compact != raw, compact.hasPrefix("https://") || compact.hasPrefix("http://"),
            let parts = URLComponents(string: compact), let host = parts.host, host.contains("."),
            parts.user == nil, parts.password == nil,
            !compact.dropFirst(8).contains("http://"), !compact.dropFirst(8).contains("https://")
        else { return nil }
        return compact
    }

    /// A conservative changed span, including deletions via a neighbouring glyph.
    /// Bounded linear work, even for long tokens; no quadratic alignment on the UI thread.
    public static func changedRange(original: String, candidate: String) -> NSRange? {
        guard original != candidate else { return nil }
        let a = Array(original.utf16)
        let b = Array(candidate.utf16)
        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix,
            a[a.count - suffix - 1] == b[b.count - suffix - 1]
        { suffix += 1 }
        if b.count == prefix + suffix { return NSRange(location: max(0, prefix - 1), length: b.isEmpty ? 0 : 1) }
        return NSRange(location: prefix, length: b.count - prefix - suffix)
    }
}

public enum OCRImageBuffer {
    public static let maximumPixels = 16_000_000
    /// A new owned buffer: retaining a CGImage crop must not retain all display pixels.
    public static func copy(_ image: CGImage, scale: Int = 1) -> CGImage? {
        guard (1...2).contains(scale), image.width > 0, image.height > 0,
            image.width <= maximumPixels / image.height / scale / scale
        else { return nil }
        let width = image.width * scale
        let height = image.height * scale
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

public struct OCRGateEvidence: Codable, Sendable {
    public let independentSources: Int
    public let corrected: Int
    public let regressed: Int
    public let baselineEdits: Int
    public let proposedEdits: Int
    public let realScreens: Bool
    public let disjointSources: Bool
    public var permitsAutomaticReplacement: Bool {
        realScreens && disjointSources && independentSources >= 30 && corrected >= 3 && regressed == 0
            && corrected <= independentSources && proposedEdits >= 0 && proposedEdits < baselineEdits
    }
    public init(
        independentSources: Int, corrected: Int, regressed: Int, baselineEdits: Int,
        proposedEdits: Int, realScreens: Bool, disjointSources: Bool
    ) {
        self.independentSources = independentSources
        self.corrected = corrected
        self.regressed = regressed
        self.baselineEdits = baselineEdits
        self.proposedEdits = proposedEdits
        self.realScreens = realScreens
        self.disjointSources = disjointSources
    }
}
