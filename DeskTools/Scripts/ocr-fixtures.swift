// Synthetic fixtures only. Keep all variants of a source in the same split.
import AppKit
import Foundation

struct Fixture: Codable {
    let id: String, sourceGroup: String, split: String, image: String, expected: String, language: String
    let realScreen: Bool
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var samples: [(String, String)] = []
var seed: UInt64 = 20_261_026
let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
for n in 0..<16 {
    let token = String(
        (0..<48).map { _ in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return alphabet[Int((seed >> 32) % UInt64(alphabet.count))]
        })
    samples.append(("https://example.test/item/\(n)?token=\(token)&src=pc_user", "automatic"))
}
let prose: [(String, [String])] = [
    (
        "english",
        [
            "Invoice 12345. Total: $98.50", "Please reply by Friday, 5:30 PM.", "Open Settings > Privacy & Security",
            "The quick brown fox jumps over the lazy dog.", "Capture text: 0 O 1 I l / ? & = _ -",
            "Meeting notes — review the release.",
        ]
    ),
    (
        "traditionalChinese",
        [
            "今天下午三點到圖書館學習。", "帳單金額：港幣 123.45 元。", "請保留原文、空格及標點符號。", "設定 → 隱私權與安全性", "中英混合 CaptureText 2026 年版本。",
            "開會記錄：星期一上午十點。",
        ]
    ),
    (
        "japanese",
        [
            "今日は図書館で日本語を勉強します。", "合計金額：1,234円です。", "設定を開いて、言語を選択してください。", "午後三時に駅で会いましょう。", "この文章をコピーして保存します。",
            "会議の予定は月曜日です。",
        ]
    ),
    (
        "korean",
        [
            "안녕하세요. 오늘 도서관에서 공부합니다.", "총 금액은 12,345원입니다.", "설정에서 언어를 선택하세요.", "월요일 오후 세 시에 만나요.", "이 문장을 복사하고 저장합니다.",
            "새로운 회의 일정을 확인하세요.",
        ]
    ),
]
for (language, texts) in prose { samples += texts.map { ($0, language) } }
var fixtures: [Fixture] = []
for (index, sample) in samples.enumerated() {
    for (condition, size, dark, jpeg) in [
        ("normal", 16.0, false, false), ("small", 11.0, false, false),
        ("dark", 13.0, true, false), ("compressed", 12.0, false, true),
    ] {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: dark ? NSColor.white : NSColor.black,
        ]
        let extent = (sample.0 as NSString).size(withAttributes: attributes)
        let width = Int(ceil(extent.width)) + 12
        let height = Int(ceil(extent.height)) + 12
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        (dark ? NSColor.black : NSColor.white).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        (sample.0 as NSString).draw(at: NSPoint(x: 6, y: 6), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        let name = "source-\(index)-\(condition)." + (jpeg ? "jpg" : "png")
        try bitmap.representation(using: jpeg ? .jpeg : .png, properties: [.compressionFactor: 0.35])!
            .write(to: output.appendingPathComponent(name))
        fixtures.append(
            Fixture(
                id: "source-\(index)-\(condition)", sourceGroup: "source-\(index)",
                split: index % 4 == 0 ? "calibration" : "holdout", image: name, expected: sample.0,
                language: sample.1, realScreen: false))
    }
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(fixtures).write(to: output.appendingPathComponent("manifest.json"))
print("Generated \(fixtures.count) images from \(samples.count) synthetic sources.")
