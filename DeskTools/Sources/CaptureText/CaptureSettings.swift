import AppKit
import CaptureCore
import DeskCore
import SwiftUI

struct CaptureSettings: View {
    @ObservedObject var model: CaptureModel
    @ObservedObject var shortcuts: CaptureShortcutStore
    @ObservedObject var screenAccess: CaptureScreenAccess
    @ObservedObject var loginItem: CaptureLoginItem
    @ObservedObject var speech: CaptureSpeechController

    init(model: CaptureModel, shortcuts: CaptureShortcutStore) {
        self.model = model
        self.shortcuts = shortcuts
        self.screenAccess = model.screenAccess
        self.loginItem = model.loginItem
        self.speech = model.speech
    }
    var body: some View {
        TabView(selection: $model.settingsPage) {
            Form {
                Section(L10n.text("文字辨認")) {
                    Picker(L10n.text("辨認語言"), selection: $model.language) {
                        ForEach(model.availableOCRLanguages) {
                            Text($0.title).tag($0).disabled(!$0.isSupported(by: model.supportedOCRCodes))
                        }
                    }.accessibilityIdentifier("capture.language")
                    Text(
                        L10n.text(
                            "自動模式使用此 Mac 支援的全部 %1$@ 個 OCR 語言／地區代碼；亦可手動指定語言。",
                            String(describing: model.supportedOCRCodes.count))
                    )
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("capture.languages.summary")
                    Toggle(L10n.text("辨認後複製"), isOn: $model.autoCopy).accessibilityLabel(L10n.text("辨認後複製"))
                        .accessibilityIdentifier(
                            "capture.autocopy")
                    Text(L10n.text("開啟時框選後直接返回原本 App；關閉時顯示結果視窗供檢查。")).font(.caption).foregroundStyle(.secondary)
                    Toggle(
                        L10n.text("保留換行"), isOn: Binding(get: { !model.singleLine }, set: { model.singleLine = !$0 }))
                    Toggle(L10n.text("累積剪貼簿"), isOn: $model.append)
                    Button(L10n.text("清除累積文字")) { model.clearAdditiveBuffer() }
                    Toggle(L10n.text("擷取後朗讀"), isOn: $model.speechAfterCapture)
                }
                Section(L10n.text("完成提示")) {
                    Toggle(L10n.text("成功提示"), isOn: $model.feedback)
                    Toggle(L10n.text("成功音效"), isOn: $model.sound)
                }
                Section(L10n.text("啟動")) {
                    Toggle(
                        L10n.text("開機登入後自動啟動"),
                        isOn: Binding(get: { loginItem.isRegistered }, set: { loginItem.setEnabled($0) })
                    ).accessibilityIdentifier("capture.login.enabled")
                    Text(loginItem.summary).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("capture.login.status")
                    if !loginItem.error.isEmpty { Text(loginItem.error).font(.caption).foregroundStyle(.red) }
                    if loginItem.status == .requiresApproval {
                        Button(L10n.text("打開登入項目設定")) { loginItem.showSettings() }
                            .accessibilityIdentifier("capture.login.settings")
                    }
                }
                Section(L10n.text("螢幕錄製")) {
                    Text(screenAccess.summary)
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("capture.permission")
                    HStack {
                        Button(L10n.text("重新檢查權限")) { Task { await screenAccess.check() } }
                            .disabled(screenAccess.state == .checking)
                            .accessibilityIdentifier("capture.permission.check")
                        Button(L10n.text("螢幕錄製權限設定…")) { screenAccess.showSettings() }
                            .accessibilityIdentifier("capture.permission.settings")
                    }
                    Text(L10n.text("圖片 OCR 不需要錄屏權限。系統已開啟但仍失敗時，可重新加入 CaptureText 並按系統提示重開 App。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label(L10n.text("一般"), systemImage: "gearshape") }.tag("general")
            Form {
                Section(L10n.text("精準重讀")) {
                    Toggle(L10n.text("短行或網址辨識後開啟校對"), isOn: $model.offerPrecision)
                        .accessibilityIdentifier("capture.precision.automatic-review")
                    Text(L10n.text("一般辨識先保留原文；校對候選需按採用才會複製。未有真實留出樣本驗證，自動替換保持停用。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L10n.text("上次選區保留於記憶體兩分鐘，供精準重讀；不儲存圖片歷史。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L10n.text("本機第二引擎")) {
                    Toggle(L10n.text("精準重讀加入第二引擎候選"), isOn: $model.secondaryEnabled)
                        .accessibilityIdentifier("capture.precision.secondary")
                        .disabled(!model.modelsInstalled)
                    Text(L10n.text("Apple Silicon 可選模型包約 86 MB，涵蓋多語言、英文及韓文。只在重讀時載入，完成即釋放；圖片不會上傳。"))
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.modelsInstalled {
                        Button(L10n.text("下載模型包")) { model.installModels() }.disabled(model.downloadingModels)
                    } else {
                        Text(L10n.text("模型已安裝；只在精準重讀時載入。"))
                    }
                    if model.downloadingModels {
                        ProgressView()
                        Button(L10n.text("取消下載")) { model.cancelModelDownload() }
                    }
                    Text(model.modelDownloadStatus).font(.caption).foregroundStyle(.secondary)
                    Text(L10n.text("第二引擎每次最多 12 行；較大選區仍可使用系統引擎。結果不保證比原文準確，請對照原圖。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label(L10n.text("精準"), systemImage: "text.magnifyingglass") }.tag(
                "precision")
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("自訂詞")).font(.headline)
                Text(L10n.text("每行一個詞，協助辨認人名、術語及專有名詞。最多採用 500 個詞。")).foregroundStyle(.secondary)
                TextEditor(text: $model.customWords).font(.system(size: 14)).border(.quaternary)
            }.padding(24).tabItem { Label(L10n.text("自訂詞"), systemImage: "text.book.closed") }.tag("words")
            Form {
                Section(L10n.text("文字轉語音")) {
                    Toggle(L10n.text("擷取後自動朗讀"), isOn: $model.speechAfterCapture)
                        .accessibilityIdentifier("capture.speech.automatic")
                    Picker(L10n.text("聲音"), selection: $speech.selectedVoiceID) {
                        Text(L10n.text("自動選擇（按文字語言）")).tag("")
                        ForEach(speech.availableVoices) { Text($0.title).tag($0.identifier) }
                        if !speech.selectedVoiceID.isEmpty,
                            !speech.availableVoices.contains(where: { $0.identifier == speech.selectedVoiceID })
                        {
                            Text(L10n.text("已選聲音不可用，請重新選擇")).tag(speech.selectedVoiceID)
                        }
                    }.accessibilityIdentifier("capture.speech.voice")
                    LabeledContent(L10n.text("語速")) {
                        HStack {
                            Text(L10n.text("慢")).font(.caption)
                            Slider(value: $speech.rate, in: CaptureSpeechController.rateRange)
                                .accessibilityIdentifier("capture.speech.rate")
                            Text(L10n.text("快")).font(.caption)
                        }.frame(width: 250)
                    }
                    Button(speech.isSpeaking ? L10n.text("停止朗讀") : L10n.text("朗讀目前結果")) { model.speak() }
                        .disabled(model.text.isEmpty).accessibilityIdentifier("capture.speech.preview")
                    if !speech.status.isEmpty {
                        Text(speech.status).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("capture.speech.settings-status")
                    }
                }
                Section {
                    Text(L10n.text("自動模式按每句／每行選聲音；繁體中文優先用廣東話，簡體中文用普通話。亦可自行選擇聲音及語速。"))
                    Text(
                        L10n.text(
                            "本機提供 %1$@ 個可用聲音；語音支援與 OCR 語言不同。需要其他聲音時，可在 macOS 輔助使用的朗讀設定下載。",
                            String(describing: speech.availableVoices.count))
                    )
                    .accessibilityIdentifier("capture.speech.voices-summary")
                }.font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped).tabItem { Label(L10n.text("朗讀"), systemImage: "speaker.wave.2") }.tag("speech")
            Form {
                Section {
                    ForEach(CaptureShortcutAction.allCases) { action in
                        LabeledContent(action.title) {
                            CaptureShortcutRecorder(action: action, shortcut: shortcuts[action]) {
                                shortcuts.update(action, to: $0)
                            }.frame(width: 145, height: 26)
                        }
                    }
                }
                if !shortcuts.error.isEmpty {
                    Text(shortcuts.error).foregroundStyle(.red).accessibilityIdentifier("capture.shortcut.error")
                }
                Text(L10n.text("按一下快捷鍵欄，再按所需組合；加入 ⌘、⌃ 或 ⌥。Esc 取消設定，Delete 清除。")).font(.caption).foregroundStyle(
                    .secondary)
                Text(L10n.text("保留／合併換行只影響該次框選，一般設定保持原狀。上次選區每次重新擷取最新畫面。")).font(.caption).foregroundStyle(.secondary)
                Text(L10n.text("框選時按 Esc 取消；剪貼簿保持原狀。")).font(.caption)
            }.formStyle(.grouped).tabItem { Label(L10n.text("快捷鍵"), systemImage: "keyboard") }.tag("shortcuts")
        }.padding(10).frame(width: 580, height: 560)
            .onAppear {
                screenAccess.refresh()
                loginItem.refresh()
                speech.refreshVoices()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                screenAccess.refresh()
                loginItem.refresh()
                speech.refreshVoices()
            }
    }
}
