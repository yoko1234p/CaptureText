import DeskCore
import Foundation

public enum TableSpreadsheet {
    public static func xlsx(_ table: RecognizedTable) throws -> Data {
        try table.validate()
        func escape(_ text: String) -> String {
            String(
                text.unicodeScalars.filter {
                    $0.value == 9 || $0.value == 10 || $0.value == 13
                        || (32...0xD7FF).contains($0.value) || (0xE000...0xFFFD).contains($0.value)
                        || (0x10000...0x10FFFF).contains($0.value)
                }.map(Character.init)
            )
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func column(_ index: Int) -> String {
            var n = index + 1
            var result = ""
            while n > 0 {
                n -= 1
                result = String(UnicodeScalar(65 + n % 26)!) + result
                n /= 26
            }
            return result
        }
        let rows = table.cells.enumerated().map { row, values in
            "<row r=\"\(row + 1)\">"
                + values.enumerated().map { col, text in
                    "<c r=\"\(column(col))\(row + 1)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escape(text))</t></is></c>"
                }.joined() + "</row>"
        }.joined()
        let files: [(String, String)] = [
            (
                "[Content_Types].xml",
                "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/></Types>"
            ),
            (
                "_rels/.rels",
                "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"
            ),
            (
                "xl/workbook.xml",
                "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"Table1\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"
            ),
            (
                "xl/_rels/workbook.xml.rels",
                "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>"
            ),
            (
                "xl/worksheets/sheet1.xml",
                "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>\(rows)</sheetData></worksheet>"
            ),
        ]
        return try archive(files.map { ($0.0, Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>" + $0.1).utf8)) })
    }
    private static func archive(_ files: [(String, Data)]) throws -> Data {
        var output = Data()
        var central = Data()
        func value<T: FixedWidthInteger>(_ number: T) -> Data {
            var n = number.littleEndian
            return withUnsafeBytes(of: &n) { Data($0) }
        }
        func crc(_ data: Data) -> UInt32 {
            var crc: UInt32 = 0xffff_ffff
            for byte in data {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb8_8320 : 0) }
            }
            return ~crc
        }
        for (path, data) in files {
            try Task.checkCancellation()
            let name = Data(path.utf8)
            let checksum = crc(data)
            let size = UInt32(data.count)
            let offset = UInt32(output.count)
            output += value(UInt32(0x0403_4b50))
            output += value(UInt16(20))
            output += value(UInt16(0x800))
            output += value(UInt16(0))
            output += value(UInt16(0))
            output += value(UInt16(33))
            output += value(checksum)
            output += value(size)
            output += value(size)
            output += value(UInt16(name.count))
            output += value(UInt16(0))
            output += name
            output += data
            central += value(UInt32(0x0201_4b50))
            central += value(UInt16(20))
            central += value(UInt16(20))
            central += value(UInt16(0x800))
            central += value(UInt16(0))
            central += value(UInt16(0))
            central += value(UInt16(33))
            central += value(checksum)
            central += value(size)
            central += value(size)
            central += value(UInt16(name.count))
            central += value(UInt16(0))
            central += value(UInt16(0))
            central += value(UInt16(0))
            central += value(UInt16(0))
            central += value(UInt32(0))
            central += value(offset)
            central += name
        }
        let offset = UInt32(output.count)
        output += central
        output += value(UInt32(0x0605_4b50))
        output += value(UInt16(0))
        output += value(UInt16(0))
        output += value(UInt16(files.count))
        output += value(UInt16(files.count))
        output += value(UInt32(central.count))
        output += value(offset)
        output += value(UInt16(0))
        guard output.count <= 25_000_000 else { throw DeskError.invalid(L10n.text("Excel 匯出超過 25 MB。")) }
        return output
    }
}
