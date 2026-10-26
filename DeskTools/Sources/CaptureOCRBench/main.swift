import CaptureCore
import Foundation
import ImageIO

struct Fixture: Codable {
    let id: String
    let sourceGroup: String
    let split: String
    let image: String
    let expected: String
    let language: OCRLanguage
    let realScreen: Bool
}
struct Measurement: Codable {
    let id: String
    let split: String
    let exact: Bool
    let edits: Int
    let characters: Int
    let punctuationExact: Bool
    let milliseconds: Double
    let precisionMilliseconds: Double
    let candidateExact: Bool
    let secondaryMilliseconds: Double?
    let secondaryExact: Bool?
}
func distance(_ a: String, _ b: String) -> Int {
    let left = Array(a)
    let right = Array(b)
    var row = Array(0...right.count)
    for (i, x) in left.enumerated() {
        var next = [i + 1] + Array(repeating: 0, count: right.count)
        for (j, y) in right.enumerated() { next[j + 1] = min(next[j] + 1, row[j + 1] + 1, row[j] + (x == y ? 0 : 1)) }
        row = next
    }
    return row.last ?? 0
}
func milliseconds(_ start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now).components
    return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
}
@main struct Benchmark {
    static func main() async throws {
        let args = CommandLine.arguments
        if args.contains("--install-models") {
            try await OCRModelPack.shared.install { message in
                FileHandle.standardError.write(Data((message + "\n").utf8))
            }
            return
        }
        guard args.count >= 3 else { throw CocoaError(.fileReadInvalidFileName) }
        let manifest = URL(fileURLWithPath: args[1])
        let output = URL(fileURLWithPath: args[2])
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: manifest))
        guard !fixtures.isEmpty, fixtures.count <= 2000,
            Set(fixtures.map(\.id)).count == fixtures.count,
            fixtures.allSatisfy({
                ["calibration", "holdout"].contains($0.split) && !$0.sourceGroup.isEmpty && $0.expected.count <= 4096
            })
        else { throw CocoaError(.fileReadCorruptFile) }
        let calibration = Set(fixtures.filter { $0.split == "calibration" }.map(\.sourceGroup))
        let holdout = Set(fixtures.filter { $0.split == "holdout" }.map(\.sourceGroup))
        guard calibration.isDisjoint(with: holdout) else { throw CocoaError(.fileReadCorruptFile) }
        var measurements: [Measurement] = []
        for fixture in fixtures {
            let measurement = try await autoreleasepool { () -> Task<Measurement, Error> in
                Task {
                    let imageURL = manifest.deletingLastPathComponent().appendingPathComponent(fixture.image)
                        .standardizedFileURL
                    guard imageURL.path.hasPrefix(manifest.deletingLastPathComponent().standardizedFileURL.path + "/"),
                        let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
                    else { throw CocoaError(.fileReadCorruptFile) }
                    let options = CaptureRecognitionOptions(
                        kind: .text, language: fixture.language, words: [], singleLine: false)
                    let cancellation = RecognitionCancellation()
                    let start = ContinuousClock.now
                    let original =
                        (try? Recognition.document(image, language: fixture.language, cancellation: cancellation))
                        ?? OCRDocument(blocks: [], singleLine: false, width: image.width, height: image.height)
                    let elapsed = milliseconds(start)
                    let retryStart = ContinuousClock.now
                    let review =
                        (try? OCRPrecision.recognize(
                            image, options: options, baseline: original, cancellation: cancellation))
                        ?? OCRPrecisionResult(original: original)
                    let retryElapsed = milliseconds(retryStart)
                    var secondary: String?
                    var secondaryElapsed: Double?
                    if args.contains("--secondary") {
                        let worker = URL(fileURLWithPath: args[0]).deletingLastPathComponent().appendingPathComponent(
                            "CaptureOCRWorker")
                        let secondStart = ContinuousClock.now
                        secondary = try? await SecondaryOCRWorker.recognize(
                            image, document: original,
                            language: fixture.language, executable: worker, cancellation: cancellation)
                        secondaryElapsed = milliseconds(secondStart)
                    }
                    // Scoring is deliberately outside all inference timers. No recognized text is logged.
                    return Measurement(
                        id: fixture.id, split: fixture.split, exact: original.text == fixture.expected,
                        edits: distance(original.text, fixture.expected), characters: fixture.expected.count,
                        punctuationExact: original.text.filter(\.isPunctuation)
                            == fixture.expected.filter(\.isPunctuation),
                        milliseconds: elapsed, precisionMilliseconds: retryElapsed,
                        candidateExact: review.candidates.contains { $0.text == fixture.expected },
                        secondaryMilliseconds: secondaryElapsed,
                        secondaryExact: secondary.map { $0 == fixture.expected })
                }
            }.value
            measurements.append(measurement)
            if measurements.count % 20 == 0 {
                FileHandle.standardError.write(Data("Completed \(measurements.count)/\(fixtures.count)\n".utf8))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(measurements).write(to: output, options: .atomic)
    }
}
