import AppKit
import CaptureCore
import DeskCore
import DeskUI
import SwiftUI

struct CaptureView: View {
    @ObservedObject var model: CaptureModel
    @ObservedObject var shortcuts: CaptureShortcutStore
    var showSettings: () -> Void
    var importFromDevice: (NSView) -> Void
    @State private var sourceVisible = false
    @ObservedObject var screenAccess: CaptureScreenAccess
    @ObservedObject var speech: CaptureSpeechController

    init(
        model: CaptureModel, shortcuts: CaptureShortcutStore, showSettings: @escaping () -> Void,
        importFromDevice: @escaping (NSView) -> Void
    ) {
        self.model = model
        self.shortcuts = shortcuts
        self.showSettings = showSettings
        self.importFromDevice = importFromDevice
        self.screenAccess = model.screenAccess
        self.speech = model.speech
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    model.capture()
                } label: {
                    Label(L10n.text("框選文字"), systemImage: "viewfinder")
                }.buttonStyle(.borderedProminent).tint(.teal)
                Button(L10n.text("精準重讀")) { model.reread() }.disabled(!model.canReread || model.busy)
                    .accessibilityIdentifier("capture.precision.reread")
                Menu {
                    Button(L10n.text("精準框選")) { model.capture(precise: true) }
                    Button(L10n.text("影片多畫面重讀")) { model.capture(video: true) }
                    Button(L10n.text("保留換行")) { model.capture(singleLine: false) }
                    Button(L10n.text("合併成一行")) { model.capture(singleLine: true) }
                    Button(L10n.text("框選表格")) { model.capture(table: true) }
                    Button(L10n.text("開啟圖片辨認表格…")) { model.openImage(table: true) }
                    Button(L10n.text("重取上次選區")) { model.capture(last: true) }.disabled(!model.hasLastSelection)
                } label: {
                    Image(systemName: "chevron.down")
                }.menuStyle(.borderlessButton).frame(width: 20)
                    .help(L10n.text("本次擷取模式"))
                Button(L10n.text("QR／條碼")) { model.capture(barcode: true) }
                Button(L10n.text("開啟圖片…")) { model.openImage() }
                CaptureDeviceImportButton(open: importFromDevice).frame(width: 110, height: 24)
                Spacer()
                if model.preview != nil {
                    Button {
                        sourceVisible.toggle()
                    } label: {
                        Image(systemName: "photo")
                    }.help(L10n.text("顯示／隱藏來源圖片"))
                }
                Button {
                    showSettings()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }.help(L10n.text("設定")).accessibilityIdentifier("capture.settings")
            }
            HStack {
                Picker(L10n.text("辨認語言"), selection: $model.language) {
                    ForEach(model.availableOCRLanguages) {
                        Text($0.title).tag($0).disabled(!$0.isSupported(by: model.supportedOCRCodes))
                    }
                }
                .frame(maxWidth: 320)
                Spacer()
                if model.busy {
                    ProgressView().controlSize(.small)
                    Button(L10n.text("取消")) { model.cancel() }
                } else {
                    Text(shortcuts[.capture].map { $0.display + L10n.text(" 框選") } ?? L10n.text("可在設定加入全域快捷鍵"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                if sourceVisible, let preview = model.preview {
                    VStack(spacing: 8) {
                        Image(nsImage: preview).resizable().scaledToFit().frame(maxWidth: 180, maxHeight: 220)
                        Text(L10n.text("本次選取 · 不儲存圖片")).font(.caption2).foregroundStyle(.secondary)
                    }.frame(width: 180).padding(12).background(
                        .quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L10n.text("辨認結果")).font(.headline)
                        Spacer()
                        Text(L10n.text("%1$@ 字元", String(describing: model.text.count))).font(.caption).foregroundStyle(
                            .secondary)
                    }
                    if !model.tables.isEmpty {
                        CaptureTableView(model: model)
                    } else {
                        TextEditor(text: $model.text).font(.system(size: 15)).scrollContentBackground(.hidden)
                            .accessibilityIdentifier("capture.result")
                            .padding(10).background(.background, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                    }
                }
            }.frame(maxHeight: .infinity)
            Text(model.message).font(.callout).foregroundStyle(model.failed ? .red : .secondary).textSelection(.enabled)
            if !speech.status.isEmpty {
                Text(speech.status).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("capture.speech.status")
            }
            if screenAccess.state == .denied {
                HStack {
                    Button(L10n.text("打開錄屏權限設定")) { screenAccess.showSettings() }
                        .accessibilityIdentifier("capture.permission.recover")
                    Button(L10n.text("重新檢查權限")) { Task { await screenAccess.check() } }
                        .accessibilityIdentifier("capture.permission.retry")
                }
            }
            HStack {
                Button {
                    AppSupport.copy(model.text)
                    model.message = L10n.text("已複製。")
                } label: {
                    Label(L10n.text("複製"), systemImage: "doc.on.doc")
                }.keyboardShortcut("c", modifiers: [.command, .shift])
                Button(speech.isSpeaking ? L10n.text("停止朗讀") : L10n.text("朗讀")) { model.speak() }
                    .accessibilityIdentifier("capture.speech.toggle")
                Button(L10n.text("匯出…")) { AppSupport.export(model.text) }
                Spacer()
                Button(L10n.text("詞卡草稿")) { model.sendVocabularyDraft() }
                    .help(L10n.text("先選取生字，再送到 NotchHub 確認釋義及原句"))
                NoteDestinationsMenu(text: model.text, source: model.collectionSource)
            }.disabled(model.text.isEmpty || model.busy)
        }.padding(16).frame(minWidth: 600, minHeight: 380)
    }
}
