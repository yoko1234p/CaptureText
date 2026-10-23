import AppKit
import Carbon
import DeskCore
import DeskUI
import SwiftUI

@MainActor final class CaptureDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model: CaptureModel
    let shortcuts: CaptureShortcutStore
    private let captureLauncher: CaptureMenuLauncher
    var window: NSWindow!
    var settings: NSWindow!
    var status: NSStatusItem!
    private let importController: CaptureImportController
    private var hotkeys: [CaptureShortcutAction: GlobalHotKey] = [:]
    private var registeredShortcuts: [CaptureShortcutAction: CaptureShortcut] = [:]
    private var ready = false
    private var pendingURLs: [URL] = []

    override convenience init() {
        self.init(model: CaptureModel(), shortcuts: CaptureShortcutStore())
    }

    init(model: CaptureModel, shortcuts: CaptureShortcutStore, captureLauncher: CaptureMenuLauncher? = nil) {
        self.model = model
        self.shortcuts = shortcuts
        self.captureLauncher = captureLauncher ?? CaptureMenuLauncher { $0.begin(on: model) }
        importController = CaptureImportController(model: model)
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppSupport.standardMenu("CaptureText")
        if let applicationMenu = NSApp.mainMenu?.items.first?.submenu {
            let services = NSMenu(title: L10n.text("服務"))
            let servicesItem = NSMenuItem(title: L10n.text("服務"), action: nil, keyEquivalent: "")
            servicesItem.submenu = services
            applicationMenu.insertItem(servicesItem, at: 1)
            NSApp.servicesMenu = services
        }
        let file = NSMenuItem(title: L10n.text("檔案"), action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: L10n.text("檔案"))
        fileMenu.delegate = importController
        fileMenu.addItem(CaptureImportController.mainMenuItem())
        file.submenu = fileMenu
        NSApp.mainMenu?.insertItem(file, at: 1)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let resultWindow = CaptureImportWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 680, height: 480)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        resultWindow.title = L10n.text("CaptureText · 結果")
        resultWindow.isReleasedWhenClosed = false
        resultWindow.minSize = NSSize(width: 620, height: 460)
        resultWindow.contentView = NSHostingView(
            rootView: CaptureView(
                model: model, shortcuts: shortcuts, showSettings: { [weak self] in self?.showSettings() },
                importFromDevice: { [weak self] view in self?.importController.presentMenu(from: view) })
        )
        resultWindow.importReceiver = importController
        resultWindow.center()
        window = resultWindow
        importController.view = window.contentView!
        window.contentViewController = importController
        NSApp.registerServicesMenuSendTypes([], returnTypes: CaptureImportController.supportedTypes)
        window.contentMinSize = NSSize(width: 600, height: 380)
        settings = AppSupport.window(
            L10n.text("CaptureText · 設定"), size: NSSize(width: 600, height: 580),
            view: CaptureSettings(model: model, shortcuts: shortcuts))
        settings.styleMask.remove(.resizable)
        model.showWindow = { [weak self] in
            if let self {
                self.model.rememberForegroundApplication()
                AppSupport.show(self.window)
            }
        }
        model.hideWindow = { [weak self] in
            self?.window.orderOut(nil)
            self?.settings.orderOut(nil)
        }
        shortcuts.registerChange = { [weak self] action, shortcut in
            self?.register(action, shortcut: shortcut) ?? false
        }
        for action in CaptureShortcutAction.allCases {
            if let shortcut = shortcuts[action], !register(action, shortcut: shortcut) {
                shortcuts.error = L10n.text(
                    "%1$@ 已被佔用；請為「%2$@」設定另一組快捷鍵。", String(describing: shortcut.display),
                    String(describing: action.title))
            }
        }
        status = NSStatusBar.system.statusItem(withLength: 26)
        let statusIcon = NSImage(
            systemSymbolName: "viewfinder", accessibilityDescription: L10n.text("CaptureText — 框選文字"))?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        statusIcon?.size = NSSize(width: 16, height: 16)
        statusIcon?.isTemplate = true
        status.button?.image = statusIcon
        status.button?.imageScaling = .scaleProportionallyDown
        status.button?.toolTip = L10n.text("CaptureText — 框選畫面文字")
        status.button?.setAccessibilityIdentifier("capture.status")
        status.button?.setAccessibilityLabel("CaptureText")
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu
        menuNeedsUpdate(menu)
        if !UserDefaults.standard.bool(forKey: "quietWorkflowIntroduced") {
            UserDefaults.standard.set(true, forKey: "quietWorkflowIntroduced")
            showSettings()
        }
        ready = true
        if !pendingURLs.isEmpty {
            let urls = pendingURLs
            pendingURLs = []
            application(NSApp, open: urls)
        }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(
            _ title: String, _ action: Selector, identifier: String? = nil,
            checked: Bool? = nil, enabled: Bool = true
        ) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            if let identifier {
                item.identifier = NSUserInterfaceItemIdentifier(identifier)
                item.setAccessibilityIdentifier(identifier)
            }
            item.isEnabled = enabled
            if let checked { item.state = checked ? .on : .off }
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        func title(_ text: String, _ action: CaptureShortcutAction) -> String {
            shortcuts[action].map { text + "    " + $0.display } ?? text
        }
        item(title(L10n.text("框選文字"), .capture), #selector(capture(_:)), identifier: "capture.menu.text")
        item(
            title(L10n.text("框選文字 · 保留換行"), .withLineBreaks), #selector(captureWithLines(_:)),
            identifier: "capture.menu.lines")
        item(
            title(L10n.text("框選文字 · 合併成一行"), .withoutLineBreaks), #selector(captureWithoutLines(_:)),
            identifier: "capture.menu.singleLine")
        item(
            title(L10n.text("重取上次選區"), .repeatSelection), #selector(lastCapture(_:)), identifier: "capture.menu.repeat",
            enabled: model.hasLastSelection)
        item(title(L10n.text("QR／條碼"), .barcodes), #selector(barcode(_:)), identifier: "capture.menu.barcode")
        item(L10n.text("開啟圖片…"), #selector(openImage(_:)))
        item(L10n.text("從 iPhone／iPad 匯入…"), #selector(importFromDevice(_:)), identifier: "capture.menu.device")
        menu.addItem(.separator())
        item(title(L10n.text("保留換行"), .toggleLineBreaks), #selector(toggleLines), checked: !model.singleLine)
        item(title(L10n.text("累積剪貼簿"), .toggleAppend), #selector(toggleAppend), checked: model.append)
        item(title(L10n.text("清除累積文字"), .clearAppend), #selector(clearAppend))
        item(title(L10n.text("擷取後朗讀"), .toggleSpeech), #selector(toggleSpeech), checked: model.speechAfterCapture)
        item(title(L10n.text("停止朗讀"), .stopSpeech), #selector(stopSpeech))
        menu.addItem(.separator())
        item(L10n.text("查看／編輯上次結果"), #selector(show), identifier: "capture.menu.result")
        item(L10n.text("更改快捷鍵…"), #selector(showShortcuts))
        item(L10n.text("設定…"), #selector(showSettings))
        item(L10n.text("結束 CaptureText"), #selector(quit))
    }

    func menuWillOpen(_ menu: NSMenu) {
        model.rememberForegroundApplication()
        captureLauncher.menuWillOpen()
    }

    func menuDidClose(_ menu: NSMenu) { captureLauncher.menuDidClose() }

    private func register(_ action: CaptureShortcutAction, shortcut: CaptureShortcut?) -> Bool {
        guard let shortcut else {
            hotkeys[action] = nil
            registeredShortcuts[action] = nil
            return true
        }
        if registeredShortcuts[action]?.conflicts(with: shortcut) == true { return true }
        let candidate = GlobalHotKey { [weak self] in self?.perform(action) }
        guard candidate.register(key: shortcut.key, modifiers: shortcut.modifiers) else { return false }
        hotkeys[action] = candidate
        registeredShortcuts[action] = shortcut
        return true
    }
    private func perform(_ action: CaptureShortcutAction) {
        if settings?.isKeyWindow == true, let recorder = settings.firstResponder as? ShortcutRecordingButton,
            recorder.isRecording, let shortcut = registeredShortcuts[action]
        {
            recorder.recordRegisteredShortcut(shortcut)
            return
        }
        switch action {
        case .capture: capture()
        case .withLineBreaks: captureWithLines()
        case .withoutLineBreaks: captureWithoutLines()
        case .repeatSelection: lastCapture()
        case .barcodes: barcode()
        case .toggleLineBreaks: toggleLines()
        case .toggleAppend: toggleAppend()
        case .clearAppend: clearAppend()
        case .toggleSpeech: toggleSpeech()
        case .stopSpeech: stopSpeech()
        }
    }
    private func requestCapture(_ request: CaptureRegionRequest, sender: Any?) {
        captureLauncher.request(request, fromMenu: sender is NSMenuItem)
        if captureLauncher.isTracking { status?.menu?.cancelTracking() }
    }

    @objc func capture(_ sender: Any? = nil) { requestCapture(.text, sender: sender) }
    @objc func captureWithLines(_ sender: Any? = nil) { requestCapture(.withLineBreaks, sender: sender) }
    @objc func captureWithoutLines(_ sender: Any? = nil) { requestCapture(.withoutLineBreaks, sender: sender) }
    @objc func lastCapture(_ sender: Any? = nil) { requestCapture(.repeatSelection, sender: sender) }
    @objc func barcode(_ sender: Any? = nil) { requestCapture(.barcodes, sender: sender) }
    @objc func openImage(_ sender: Any? = nil) {
        captureLauncher.perform(fromMenu: sender is NSMenuItem) { [weak self] in self?.model.openImage() }
        if captureLauncher.isTracking { status?.menu?.cancelTracking() }
    }
    @objc func importFromDevice(_ sender: Any? = nil) {
        captureLauncher.perform(fromMenu: sender is NSMenuItem) { [weak self] in
            guard let self else { return }
            self.show()
            // Give window activation and native button layout one turn before device discovery.
            CaptureMenuLauncher.afterMenuTracking { [weak self] in self?.importController.presentMenu() }
        }
        if captureLauncher.isTracking { status?.menu?.cancelTracking() }
    }
    @objc func toggleLines() { if !model.toggleSelectionOption("l") { model.singleLine.toggle() } }
    @objc func toggleAppend() { if !model.toggleSelectionOption("h") { model.append.toggle() } }
    @objc func clearAppend() { model.clearAdditiveBuffer() }
    @objc func toggleSpeech() { if !model.toggleSelectionOption("s") { model.speechAfterCapture.toggle() } }
    @objc func stopSpeech() { model.stopSpeaking() }
    @objc func show() { model.showWindow() }
    @objc func showSettings() { AppSupport.show(settings) }
    @objc func showShortcuts() {
        model.settingsPage = "shortcuts"
        AppSupport.show(settings)
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard ready else {
            pendingURLs = Array(urls.prefix(1))
            return
        }
        for url in urls.prefix(1) {
            if url.isFileURL {
                model.openImage(url)
            } else if url.scheme == "capturetext", url.host == "capture", url.query == nil {
                model.capture()
            } else if url.scheme == "capturetext", url.host == "settings", url.query == nil {
                showSettings()
            } else {
                show()
            }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        captureLauncher.cancelPending()
        model.cancel(show: false)
        model.stopSpeaking()
    }
}

@main enum CaptureMain {
    @MainActor static func main() {
        if L10n.catalog.printDiagnosticsIfRequested() { return }
        let app = NSApplication.shared
        let delegate = CaptureDelegate()
        app.delegate = delegate
        // Configure the signed main app before AppKit waits for desktop launch
        // events. This also supports setup while the current desktop is locked.
        if CommandLine.arguments.contains("--enable-login") {
            delegate.model.loginItem.setEnabled(true)
            let item = delegate.model.loginItem
            if let data = try? JSONSerialization.data(withJSONObject: [
                "status": item.status.rawValue, "summary": item.summary, "error": item.error,
            ]) {
                print(String(decoding: data, as: UTF8.self))
            }
            if CommandLine.arguments.contains("--startup-only") { return }
        }
        withExtendedLifetime(delegate) { app.run() }
    }
}
