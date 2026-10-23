import AppKit
import CaptureCore
import DeskCore
import DeskUI
import SwiftUI
import UniformTypeIdentifiers

extension CaptureModel {
    var currentTable: RecognizedTable? { tables.indices.contains(tableIndex) ? tables[tableIndex] : nil }
    func editTable(_ edit: (inout RecognizedTable) -> Void) {
        guard var table = currentTable else { return }
        edit(&table)
        do {
            try table.validate()
            let output = try table.delimited(separator: "\t", protectFormulas: protectTableFormulas)
            tables[tableIndex] = table
            text = output
            failed = false
        } catch {
            failed = true
            message = error.localizedDescription
        }
    }
    func exportTable(excel: Bool) {
        guard let table = currentTable else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = excel ? L10n.text("表格.xlsx") : L10n.text("表格.csv")
        panel.allowedContentTypes = [UTType(filenameExtension: excel ? "xlsx" : "csv") ?? .data]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let protect = protectTableFormulas
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let data =
                        try excel
                        ? TableSpreadsheet.xlsx(table)
                        : Data([0xef, 0xbb, 0xbf]) + Data(table.delimited(protectFormulas: protect).utf8)
                    try BoundedFile.write(data, to: destination)
                }.value
                message = L10n.text("已匯出 ") + destination.lastPathComponent
            } catch {
                failed = true
                message = error.localizedDescription
            }
        }
    }
}

struct CaptureTableView: View {
    @ObservedObject var model: CaptureModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker(L10n.text("表格"), selection: $model.tableIndex) {
                    ForEach(model.tables.indices, id: \.self) {
                        Text(L10n.text("表格 %1$@", String(describing: $0 + 1))).tag($0)
                    }
                }.frame(width: 140)
                Spacer()
                Button(L10n.text("加行")) {
                    model.editTable { $0.cells.append(Array(repeating: "", count: $0.columnCount)) }
                }
                Button(L10n.text("加欄")) {
                    model.editTable { table in for row in table.cells.indices { table.cells[row].append("") } }
                }
                Button("CSV…") { model.exportTable(excel: false) }
                Button("Excel…") { model.exportTable(excel: true) }
            }
            if let table = model.currentTable {
                Text(table.notice).font(.caption).foregroundStyle(.secondary)
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 3) {
                            Text(L10n.text("行")).frame(width: 36)
                            ForEach(0..<table.columnCount, id: \.self) { column in
                                Menu(L10n.text("欄 %1$@", String(describing: column + 1))) {
                                    Button(L10n.text("向左移")) {
                                        model.editTable { grid in
                                            guard column > 0, column < grid.columnCount else { return }
                                            for row in grid.cells.indices { grid.cells[row].swapAt(column, column - 1) }
                                        }
                                    }.disabled(column == 0)
                                    Button(L10n.text("向右移")) {
                                        model.editTable { grid in
                                            guard column >= 0, column + 1 < grid.columnCount else { return }
                                            for row in grid.cells.indices { grid.cells[row].swapAt(column, column + 1) }
                                        }
                                    }.disabled(column + 1 == table.columnCount)
                                    Button(L10n.text("刪除此欄"), role: .destructive) {
                                        model.editTable { grid in
                                            guard grid.columnCount > 1, column >= 0, column < grid.columnCount else {
                                                return
                                            }
                                            for row in grid.cells.indices { grid.cells[row].remove(at: column) }
                                        }
                                    }.disabled(table.columnCount <= 1)
                                }.frame(width: 140)
                            }
                        }.font(.caption)
                        ForEach(table.cells.indices, id: \.self) { row in
                            HStack(spacing: 3) {
                                Menu(String(row + 1)) {
                                    Button(L10n.text("刪除此行"), role: .destructive) {
                                        model.editTable { grid in
                                            if grid.cells.count > 1, grid.cells.indices.contains(row) {
                                                grid.cells.remove(at: row)
                                            }
                                        }
                                    }.disabled(table.cells.count <= 1)
                                }.frame(width: 36)
                                ForEach(0..<table.columnCount, id: \.self) { column in
                                    TextField(
                                        "",
                                        text: Binding(
                                            get: {
                                                guard let value = model.currentTable, value.cells.indices.contains(row),
                                                    value.cells[row].indices.contains(column)
                                                else { return "" }
                                                return value.cells[row][column]
                                            },
                                            set: { text in
                                                model.editTable { grid in
                                                    if grid.cells.indices.contains(row),
                                                        grid.cells[row].indices.contains(column)
                                                    {
                                                        grid.cells[row][column] = text
                                                    }
                                                }
                                            }
                                        )
                                    ).textFieldStyle(.roundedBorder).frame(width: 140)
                                        .accessibilityIdentifier("capture.table.cell.\(row).\(column)")
                                }
                            }
                        }
                    }.padding(4)
                }.border(.quaternary)
                Toggle(L10n.text("CSV／複製時保護公式字串"), isOn: $model.protectTableFormulas).font(.caption)
                    .onChange(of: model.protectTableFormulas) { _, _ in model.editTable { _ in } }
            }
        }.onChange(of: model.tableIndex) { _, _ in model.editTable { _ in } }
    }
}
