import AppKit
import DeskCore
import SwiftUI

struct CaptureShortcutRecorder: NSViewRepresentable {
    let action: CaptureShortcutAction
    let shortcut: CaptureShortcut?
    var changed: (CaptureShortcut?) -> Bool

    func makeNSView(context: Context) -> ShortcutRecordingButton {
        let button = ShortcutRecordingButton()
        button.setAccessibilityLabel(action.title + L10n.text("快捷鍵"))
        button.setAccessibilityIdentifier("capture.shortcut." + action.rawValue)
        return button
    }
    func updateNSView(_ button: ShortcutRecordingButton, context: Context) {
        button.shortcut = shortcut
        button.changed = changed
        button.refreshTitle()
    }
    static func dismantleNSView(_ button: ShortcutRecordingButton, coordinator: ()) {
        button.stopRecording()
    }
}

@MainActor final class ShortcutRecordingButton: NSButton {
    var shortcut: CaptureShortcut?
    var changed: (CaptureShortcut?) -> Bool = { _ in false }
    private var monitor: Any?
    private var windowObserver: NSObjectProtocol?
    var isRecording: Bool { monitor != nil }
    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        controlSize = .small
        target = self
        action = #selector(startRecording)
        toolTip = L10n.text("按一下再輸入快捷鍵；Esc 取消，Delete 清除。")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refreshTitle() {
        if monitor == nil { title = shortcut?.display ?? L10n.text("設定…") }
    }
    @objc private func startRecording() {
        stopRecording()
        window?.makeFirstResponder(self)
        title = L10n.text("請按快捷鍵…")
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stopRecording() }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.window?.isKeyWindow == true, self.window?.firstResponder === self else {
                self.stopRecording()
                return event
            }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.keyCode == 53, modifiers.isEmpty {
                self.stopRecording()
            } else if [51, 117].contains(event.keyCode), modifiers.isEmpty {
                self.stopRecording()
                _ = self.changed(nil)
            } else if let shortcut = CaptureShortcut.from(event) {
                self.recordRegisteredShortcut(shortcut)
            } else {
                self.title = L10n.text("請加 ⌘／⌃／⌥")
            }
            return nil
        }
    }
    func recordRegisteredShortcut(_ shortcut: CaptureShortcut) {
        guard isRecording else { return }
        stopRecording()
        _ = changed(shortcut)
    }
    func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
            self.windowObserver = nil
        }
        refreshTitle()
    }
    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }
}
