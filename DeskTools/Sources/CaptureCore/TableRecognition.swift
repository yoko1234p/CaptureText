import CoreGraphics
import DeskCore
import Foundation
import Vision

public enum TableRecognition {
    public static func recognize(
        _ image: CGImage, language: OCRLanguage, words: [String], cancellation: RecognitionCancellation
    ) async throws -> [RecognizedTable] {
        try cancellation.check()
        if #available(macOS 26, *) {
            do {
                var request = RecognizeDocumentsRequest()
                request.barcodeDetectionOptions.enabled = false
                request.textRecognitionOptions.automaticallyDetectLanguage = language == .automatic
                request.textRecognitionOptions.customWords = Array(words.prefix(500))
                request.textRecognitionOptions.maximumCandidateCount = 1
                if language != .automatic {
                    request.textRecognitionOptions.recognitionLanguages = language.primaryCodes.map {
                        Locale.Language(identifier: $0)
                    }
                }
                let observations = try await request.perform(on: image)
                try cancellation.check()
                var tables: [RecognizedTable] = []
                for table in observations.flatMap({ $0.document.tables }).prefix(20) {
                    let rows = table.rows.count
                    let columns = table.columns.count
                    guard rows > 0, columns > 0, rows <= 1000, columns <= 64, rows * columns <= 20_000 else {
                        throw DeskError.invalid(L10n.text("原生表格超過處理上限，請縮小選區。"))
                    }
                    var cells = Array(repeating: Array(repeating: "", count: columns), count: rows)
                    for row in 0..<rows {
                        for column in 0..<columns {
                            if let cell = table.cell(row: row, col: column), cell.rowRange.lowerBound == row,
                                cell.columnRange.lowerBound == column
                            {
                                cells[row][column] = cell.content.text.transcript
                            }
                        }
                    }
                    let result = RecognizedTable(cells: cells, notice: L10n.text("系統表格辨認。合併格文字保留在左上格，其餘留空；匯出前請核對。"))
                    try result.validate()
                    tables.append(result)
                }
                if !tables.isEmpty { return tables }
            } catch {
                try cancellation.check()
                try Task.checkCancellation()
            }
        }
        return try await Task.detached(priority: .userInitiated) {
            let observations = try Recognition.textObservations(
                image, language: language, words: words, cancellation: cancellation)
            var boxes: [TableTextBox] = []
            let expression = try NSRegularExpression(pattern: "\\S+")
            for observation in observations {
                try cancellation.check()
                guard let candidate = observation.topCandidates(1).first else { continue }
                for match in expression.matches(
                    in: candidate.string, range: NSRange(candidate.string.startIndex..., in: candidate.string))
                {
                    guard let range = Range(match.range, in: candidate.string) else { continue }
                    let bounds = (try? candidate.boundingBox(for: range))?.boundingBox ?? observation.boundingBox
                    boxes.append(TableTextBox(text: String(candidate.string[range]), bounds: bounds))
                }
            }
            return [try TableGeometry.infer(boxes)]
        }.value
    }
}
