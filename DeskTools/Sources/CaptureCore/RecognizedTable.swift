import CoreGraphics
import DeskCore
import Foundation

public struct RecognizedTable: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var cells: [[String]]
    public var notice: String
    public init(cells: [[String]], notice: String = L10n.text("請核對欄位、空白格及數字，必要時直接修改。")) {
        self.cells = cells
        self.notice = notice
    }
    public var columnCount: Int { cells.map(\.count).max() ?? 0 }
    public func validate() throws {
        guard !cells.isEmpty, cells.count <= 1000, (1...64).contains(columnCount), cells.count * columnCount <= 20_000,
            cells.allSatisfy({ $0.count == columnCount && $0.allSatisfy({ $0.utf8.count <= 8192 }) }),
            cells.flatMap({ $0 }).reduce(0, { $0 + $1.utf8.count }) <= 1_000_000
        else { throw DeskError.invalid(L10n.text("表格上限為 1,000 行、64 欄、20,000 格及 1 MB 文字，請縮小選區。")) }
    }
    public func delimited(separator: String = ",", protectFormulas: Bool = true) throws -> String {
        try validate()
        return cells.map { row in
            row.map { source in
                var value = source
                if protectFormulas, let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first,
                    "=+-@".contains(first)
                {
                    value = "'" + value
                }
                if value.contains(separator) || value.contains("\"") || value.contains("\n") || value.contains("\r") {
                    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return value
            }.joined(separator: separator)
        }.joined(separator: "\r\n")
    }
}

public struct TableTextBox: Sendable {
    public var text: String
    public var bounds: CGRect
    public init(text: String, bounds: CGRect) {
        self.text = text
        self.bounds = bounds
    }
}

public enum TableGeometry {
    public static func infer(_ boxes: [TableTextBox]) throws -> RecognizedTable {
        guard !boxes.isEmpty, boxes.count <= 20_000 else { throw DeskError.invalid(L10n.text("未找到可用的表格文字，或選區過大。")) }
        let ordered = boxes.sorted {
            $0.bounds.midY == $1.bounds.midY ? $0.bounds.minX < $1.bounds.minX : $0.bounds.midY > $1.bounds.midY
        }
        var rows: [[TableTextBox]] = []
        for box in ordered {
            if let last = rows.last, let first = last.first,
                abs(first.bounds.midY - box.bounds.midY) <= max(first.bounds.height, box.bounds.height) * 0.5
            {
                rows[rows.count - 1].append(box)
            } else {
                rows.append([box])
            }
        }
        var blocks: [[TableTextBox]] = []
        for row in rows {
            var combined: [TableTextBox] = []
            for box in row.sorted(by: { $0.bounds.minX < $1.bounds.minX }) {
                if var last = combined.last,
                    box.bounds.minX - last.bounds.maxX <= max(0.008, min(last.bounds.height, box.bounds.height) * 0.6)
                {
                    last.text += " " + box.text
                    last.bounds = last.bounds.union(box.bounds)
                    combined[combined.count - 1] = last
                } else {
                    combined.append(box)
                }
            }
            blocks.append(combined)
        }
        var anchors: [CGFloat] = []
        for block in blocks.flatMap({ $0 }).sorted(by: { $0.bounds.minX < $1.bounds.minX }) {
            if !anchors.contains(where: { abs($0 - block.bounds.minX) < 0.025 }) { anchors.append(block.bounds.minX) }
        }
        guard (1...64).contains(anchors.count), blocks.count <= 1000, blocks.count * anchors.count <= 20_000 else {
            throw DeskError.invalid(L10n.text("推算欄位太多，請縮小選區或使用有清晰欄距的圖片。"))
        }
        let cells = blocks.map { row -> [String] in
            var values = Array(repeating: "", count: anchors.count)
            for block in row {
                let column =
                    anchors.indices.min(by: {
                        abs(anchors[$0] - block.bounds.minX) < abs(anchors[$1] - block.bounds.minX)
                    }) ?? 0
                values[column] += (values[column].isEmpty ? "" : " ") + block.text
            }
            return values
        }
        let result = RecognizedTable(cells: cells, notice: L10n.text("按文字位置推算欄位，請人工校正；空白格與合併格可能需要調整。"))
        try result.validate()
        return result
    }
}
