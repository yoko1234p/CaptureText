import AppKit
import CaptureCore
import Foundation
import XCTest

final class CaptureTableTests: XCTestCase {
    func testGeometryPreservesMissingCellsInsteadOfShiftingColumns() throws {
        let boxes = [
            TableTextBox(text: "Name", bounds: CGRect(x: 0.05, y: 0.8, width: 0.1, height: 0.04)),
            TableTextBox(text: "Price", bounds: CGRect(x: 0.6, y: 0.8, width: 0.1, height: 0.04)),
            TableTextBox(text: "Apple", bounds: CGRect(x: 0.05, y: 0.6, width: 0.1, height: 0.04)),
            TableTextBox(text: "9.99", bounds: CGRect(x: 0.6, y: 0.4, width: 0.1, height: 0.04)),
        ]
        let table = try TableGeometry.infer(boxes)
        XCTAssertEqual(table.cells, [["Name", "Price"], ["Apple", ""], ["", "9.99"]])
    }
    func testCSVQuotesUnicodeAndProtectsFormulaStrings() throws {
        let table = RecognizedTable(cells: [["001", "中文,한국어", "say \"yes\""], ["=SUM(A1)", "line\nline", "-2"]])
        let output = try table.delimited()
        XCTAssertTrue(output.contains("001,\"中文,한국어\",\"say \"\"yes\"\"\""))
        XCTAssertTrue(output.contains("'=SUM(A1)"))
        XCTAssertFalse(try table.delimited(protectFormulas: false).contains("'=SUM"))
        XCTAssertThrowsError(try RecognizedTable(cells: [["a"], ["a", "b"]]).validate())
    }
    func testExcelIsValidZipWithEscapedTextCellsAndLeadingZeroes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("table.xlsx")
        let data = try TableSpreadsheet.xlsx(.init(cells: [["001", "中文 & <tag>", "=1+1"]]))
        try data.write(to: file)
        func unzip(_ arguments: [String]) throws -> (Int32, String) {
            let process = Process(); let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); process.arguments = arguments
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        XCTAssertEqual(try unzip(["-tqq", file.path]).0, 0)
        let xml = try unzip(["-p", file.path, "xl/worksheets/sheet1.xml"]).1
        XCTAssertTrue(xml.contains("001")); XCTAssertTrue(xml.contains("中文 &amp; &lt;tag&gt;"))
        XCTAssertTrue(xml.contains("t=\"inlineStr\"")); XCTAssertFalse(xml.contains("<f>"))
    }
    @MainActor func testNativeDocumentRecognitionOnOwnedTableImage() async throws {
        let image = NSImage(size: NSSize(width: 1000, height: 400))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 400).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black]
        for (row, values) in [["Item", "Qty", "Price"], ["Apple", "2", "9.99"], ["Pear", "3", "4.50"]].enumerated() {
            for (column, text) in values.enumerated() { (text as NSString).draw(at: NSPoint(x: 50 + column * 300, y: 310 - row * 110), withAttributes: attributes) }
        }
        image.unlockFocus()
        var rect = NSRect(origin: .zero, size: image.size)
        let bitmap = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let result = try await TableRecognition.recognize(bitmap, language: .english, words: [], cancellation: RecognitionCancellation())
        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.flatMap(\.cells).flatMap({ $0 }).joined(separator: " ").contains("Apple"))
        for table in result { try table.validate() }
    }
}
