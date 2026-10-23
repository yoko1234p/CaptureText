import AppKit
import DeskCore
import ImageIO
import SwiftUI

@MainActor
final class CaptureImportController: NSViewController, @preconcurrency NSServicesMenuRequestor, NSMenuDelegate {
    private let model: CaptureModel
    private var deviceMenu: NSMenu?
    override var acceptsFirstResponder: Bool { true }
    static var supportedTypes: [NSPasteboard.PasteboardType] {
        let bitmapTypes = CGImageSourceCopyTypeIdentifiers() as? [String] ?? []
        var seen = Set<String>()
        return ([NSPasteboard.PasteboardType.pdf.rawValue, "public.image"] + NSImage.imageTypes + bitmapTypes)
            .filter { seen.insert($0).inserted }.map { NSPasteboard.PasteboardType($0) }
    }
    init(model: CaptureModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func mainMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: L10n.text("從 iPhone／iPad 匯入"), action: nil, keyEquivalent: "")
        item.identifier = NSMenuItem.importFromDeviceIdentifier
        return item
    }

    private func importButton(in view: NSView) -> DeviceImportButton? {
        if let button = view as? DeviceImportButton { return button }
        return view.subviews.lazy.compactMap { self.importButton(in: $0) }.first
    }

    func presentMenu() {
        view.layoutSubtreeIfNeeded()
        presentMenu(from: importButton(in: view) ?? view)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard isViewLoaded else { return }
        _ = prepareRequestor(from: importButton(in: view) ?? view)
    }

    func menuNeedsUpdate(_ menu: NSMenu) { menuWillOpen(menu) }

    private func prepareRequestor(from source: NSView) -> Bool {
        guard let window = source.window else { return false }
        if let button = source as? DeviceImportButton {
            button.importReceiver = self
            return window.makeFirstResponder(button)
        }
        return window.makeFirstResponder(self)
    }
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        if let returnType, Self.supportedTypes.contains(returnType) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        for type in Self.supportedTypes where pasteboard.types?.contains(type) == true {
            guard let data = pasteboard.data(forType: type), !data.isEmpty else { continue }
            model.importDocument(data)
            return true
        }
        return false
    }
    func contextualMenu(from source: NSView) -> NSMenu? {
        guard prepareRequestor(from: source) else { return nil }
        let menu = NSMenu(title: L10n.text("從 iPhone／iPad 匯入"))
        menu.delegate = self
        menu.allowsContextMenuPlugIns = true
        let hint = NSMenuItem(title: L10n.text("同一 Apple 帳戶 · iPhone 靠近並開啟 Wi-Fi／藍牙"), action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        return menu
    }

    func presentMenu(from source: NSView) {
        guard let window = source.window, let menu = contextualMenu(from: source) else { return }
        // Continuity delivers its result asynchronously, after menu tracking ends.
        deviceMenu = menu
        guard
            let event = NSEvent.mouseEvent(
                with: .rightMouseDown, location: source.convert(NSPoint(x: 0, y: source.bounds.maxY), to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
        else { return }
        // AppKit inserts the real, available-device camera and scanner actions.
        NSMenu.popUpContextMenu(menu, with: event, for: source)
    }
}

@MainActor final class CaptureImportWindow: NSWindow {
    weak var importReceiver: CaptureImportController?
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        // Menu tracking can restore focus to SwiftUI's plain text editor. The
        // persistent window responder must still expose the photo/scan receiver.
        if let returnType, CaptureImportController.supportedTypes.contains(returnType), let importReceiver {
            return importReceiver
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
}

struct CaptureDeviceImportButton: NSViewRepresentable {
    var open: (NSView) -> Void
    func makeNSView(context: Context) -> DeviceImportButton {
        let button = DeviceImportButton()
        button.title = "iPhone／iPad…"
        button.bezelStyle = .rounded
        button.setAccessibilityIdentifier("capture.import-device")
        button.setAccessibilityLabel(L10n.text("從 iPhone 或 iPad 匯入照片或掃描文件"))
        button.toolTip = L10n.text("使用連續互通相機拍攝照片或掃描文件，直接辨認文字。")
        return button
    }
    func updateNSView(_ button: DeviceImportButton, context: Context) { button.open = open }
}

@MainActor final class DeviceImportButton: NSButton {
    var open: (NSView) -> Void = { _ in }
    weak var importReceiver: CaptureImportController?
    override var acceptsFirstResponder: Bool { true }
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        // SwiftUI controls have their own responder wrappers. The context-menu owner
        // explicitly names the OCR receiver rather than depending on that chain.
        if let returnType, CaptureImportController.supportedTypes.contains(returnType), let importReceiver {
            return importReceiver
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
    init() {
        super.init(frame: .zero)
        target = self
        action = #selector(showMenu)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func showMenu() { open(self) }
}
