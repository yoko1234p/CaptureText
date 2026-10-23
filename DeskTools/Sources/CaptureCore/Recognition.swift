import CoreGraphics
import DeskCore
import Foundation
import ImageIO
import Vision

public enum OCRLanguage: String, CaseIterable, Identifiable, Sendable {
    case automatic, traditionalChinese, simplifiedChinese, japanese, korean, english
    case traditionalCantonese, simplifiedCantonese, french, italian, german, spanish, portuguese
    case russian, ukrainian, thai, vietnamese, arabic, turkish, indonesian, czech, danish, dutch
    case norwegian, malay, polish, romanian, swedish, finnish, hindi, marathi
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: return L10n.text("自動（所有支援語言）")
        case .traditionalChinese: return L10n.text("繁體中文")
        case .simplifiedChinese: return L10n.text("简体中文")
        case .japanese: return L10n.text("日本語")
        case .korean: return L10n.text("한국어（韓文）")
        case .english: return "English"
        case .traditionalCantonese: return L10n.text("廣東話（繁體）")
        case .simplifiedCantonese: return L10n.text("广东话（简体）")
        case .french: return L10n.text("Français（法文）")
        case .italian: return L10n.text("Italiano（意大利文）")
        case .german: return L10n.text("Deutsch（德文）")
        case .spanish: return L10n.text("Español（西班牙文）")
        case .portuguese: return L10n.text("Português（葡萄牙文）")
        case .russian: return L10n.text("Русский（俄文）")
        case .ukrainian: return L10n.text("Українська（烏克蘭文）")
        case .thai: return L10n.text("ไทย（泰文）")
        case .vietnamese: return L10n.text("Tiếng Việt（越南文）")
        case .arabic: return L10n.text("العربية（阿拉伯文）")
        case .turkish: return L10n.text("Türkçe（土耳其文）")
        case .indonesian: return L10n.text("Bahasa Indonesia（印尼文）")
        case .czech: return L10n.text("Čeština（捷克文）")
        case .danish: return L10n.text("Dansk（丹麥文）")
        case .dutch: return L10n.text("Nederlands（荷蘭文）")
        case .norwegian: return L10n.text("Norsk（挪威文）")
        case .malay: return L10n.text("Bahasa Melayu（馬來文）")
        case .polish: return L10n.text("Polski（波蘭文）")
        case .romanian: return L10n.text("Română（羅馬尼亞文）")
        case .swedish: return L10n.text("Svenska（瑞典文）")
        case .finnish: return L10n.text("Suomi（芬蘭文）")
        case .hindi: return L10n.text("हिन्दी（印地文）")
        case .marathi: return L10n.text("मराठी（馬拉地文）")
        }
    }
    public var primaryCodes: [String] {
        switch self {
        case .automatic: return ["zh-Hant", "zh-Hans", "ja-JP", "ko-KR", "en-US"]
        case .traditionalChinese: return ["zh-Hant"]
        case .simplifiedChinese: return ["zh-Hans"]
        case .japanese: return ["ja-JP"]
        case .korean: return ["ko-KR"]
        case .english: return ["en-US"]
        case .traditionalCantonese: return ["yue-Hant"]
        case .simplifiedCantonese: return ["yue-Hans"]
        case .french: return ["fr-FR"]
        case .italian: return ["it-IT"]
        case .german: return ["de-DE"]
        case .spanish: return ["es-ES"]
        case .portuguese: return ["pt-BR", "pt-PT"]
        case .russian: return ["ru-RU"]
        case .ukrainian: return ["uk-UA"]
        case .thai: return ["th-TH"]
        case .vietnamese: return ["vi-VT", "vi-VN"]
        case .arabic: return ["ar-SA", "ars-SA"]
        case .turkish: return ["tr-TR"]
        case .indonesian: return ["id-ID"]
        case .czech: return ["cs-CZ"]
        case .danish: return ["da-DK"]
        case .dutch: return ["nl-NL"]
        case .norwegian: return ["nb-NO", "nn-NO", "no-NO"]
        case .malay: return ["ms-MY"]
        case .polish: return ["pl-PL"]
        case .romanian: return ["ro-RO"]
        case .swedish: return ["sv-SE"]
        case .finnish: return ["fi-FI"]
        case .hindi: return ["hi-IN"]
        case .marathi: return ["mr-IN"]
        }
    }

    public var codes: [String] { self == .automatic || self == .english ? primaryCodes : primaryCodes + ["en-US"] }

    public func isSupported(by codes: [String]) -> Bool {
        self == .automatic || primaryCodes.contains(where: codes.contains)
    }

    /// Keep common languages first without restricting automatic detection to them.
    public func recognitionCodes(supported: [String]) -> [String] {
        let candidates = self == .automatic ? codes + supported : codes
        var seen = Set<String>()
        return candidates.filter { supported.contains($0) && seen.insert($0).inserted }
    }
}

public enum SelectionGeometry {
    /// Input is local AppKit points (bottom-left); CGImage crop uses top-left pixels.
    public static func pixelRect(selection: CGRect, bounds: CGRect, imageWidth: Int, imageHeight: Int) -> CGRect? {
        let rect = selection.standardized.intersection(bounds)
        guard !rect.isNull, rect.width >= 3, rect.height >= 3, bounds.width > 0, bounds.height > 0,
            imageWidth > 0, imageHeight > 0
        else { return nil }
        let sx = CGFloat(imageWidth) / bounds.width
        let sy = CGFloat(imageHeight) / bounds.height
        return CGRect(
            x: (rect.minX - bounds.minX) * sx, y: (bounds.maxY - rect.maxY) * sy,
            width: rect.width * sx, height: rect.height * sy
        )
        .integral.intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
    }
}

public enum Recognition {
    public static func supportedLanguageCodes() throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return try request.supportedRecognitionLanguages()
    }

    public static func image(from url: URL) throws -> CGImage {
        let data = try BoundedFile.read(url, limit: 40_000_000)
        return try image(data: data)
    }

    public static func image(data: Data) throws -> CGImage {
        guard data.count <= 40_000_000 else { throw DeskError.invalid(L10n.text("圖片最多 40 MB。")) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0, width <= 30_000, height <= 30_000,
            width * height <= 80_000_000
        else { throw DeskError.invalid(L10n.text("無法讀取圖片或圖片尺寸過大。")) }
        // ImageIO applies EXIF orientation before OCR; do not silently read a rotated photo sideways.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 6000,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw DeskError.invalid(L10n.text("無法解碼圖片。"))
        }
        return image
    }

    public static func text(
        _ image: CGImage, language: OCRLanguage, words: [String] = [], singleLine: Bool = false,
        cancellation: RecognitionCancellation? = nil
    )
        throws -> String
    {
        var observations = try textObservations(image, language: language, words: words, cancellation: cancellation)
        if language == .automatic {
            let detector = VNDetectTextRectanglesRequest()
            try cancellation?.begin(detector)
            do { try VNImageRequestHandler(cgImage: image, orientation: .up).perform([detector]) } catch {
                cancellation?.finish()
                throw error
            }
            cancellation?.finish()
            try cancellation?.check()
            let regions = (detector.results ?? []).map(\.boundingBox).filter { region in
                !observations.contains { covers($0.boundingBox, region) }
            }
            for region in regions {
                try cancellation?.check()
                // Text detection often omits punctuation at the edge of a line.
                let padded = region.insetBy(dx: -0.03, dy: -0.015).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                let recovered = try textObservations(
                    image, language: language, words: words, region: padded, cancellation: cancellation)
                for observation in recovered
                where !observations.contains(where: { covers($0.boundingBox, observation.boundingBox) }) {
                    observations.append(observation)
                }
            }
            if !regions.isEmpty {
                observations.sort {
                    if $0.boundingBox.midY != $1.boundingBox.midY { return $0.boundingBox.midY > $1.boundingBox.midY }
                    return $0.boundingBox.minX < $1.boundingBox.minX
                }
            }
        }
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else { throw RecognitionTextError.noText }
        return lines.joined(separator: singleLine ? " " : "\n")
    }

    private static func covers(_ existing: CGRect, _ candidate: CGRect) -> Bool {
        let intersection = existing.intersection(candidate)
        return !intersection.isNull
            && intersection.width * intersection.height >= candidate.width * candidate.height * 0.5
    }

    static func textObservations(
        _ image: CGImage, language: OCRLanguage, words: [String], region: CGRect? = nil,
        cancellation: RecognitionCancellation?
    ) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        try cancellation?.begin(request)
        defer { cancellation?.finish() }
        request.recognitionLevel = .accurate
        let supported = try request.supportedRecognitionLanguages()
        guard language.isSupported(by: supported) else { throw DeskError.invalid(L10n.text("系統不支援選擇的 OCR 語言。")) }
        request.recognitionLanguages = language.recognitionCodes(supported: supported)
        guard !request.recognitionLanguages.isEmpty else { throw DeskError.invalid(L10n.text("系統不支援選擇的 OCR 語言。")) }
        request.automaticallyDetectsLanguage = language == .automatic
        request.usesLanguageCorrection = true
        request.customWords = Array(words.prefix(500))
        if let region { request.regionOfInterest = region }
        try cancellation?.check()
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        try cancellation?.check()
        return request.results ?? []
    }

    public static func barcodes(_ image: CGImage, cancellation: RecognitionCancellation? = nil) throws -> String {
        let request = VNDetectBarcodesRequest()
        try cancellation?.begin(request)
        defer { cancellation?.finish() }
        try cancellation?.check()
        try VNImageRequestHandler(cgImage: image).perform([request])
        try cancellation?.check()
        let values = (request.results ?? []).compactMap(\.payloadStringValue)
        guard !values.isEmpty else { throw DeskError.invalid(L10n.text("沒有辨認到 QR／條碼。")) }
        return Array(NSOrderedSet(array: values)).compactMap { $0 as? String }.joined(separator: "\n")
    }
}

public enum RecognitionTextError: LocalizedError {
    case noText
    public var errorDescription: String? { L10n.text("選取範圍沒有辨認到文字，請放大或重新選取。") }
}
