import AppKit
import Carbon
import Combine
import DeskCore
import Foundation

enum CaptureShortcutAction: String, CaseIterable, Identifiable {
    case precise, reread, video, capture, withLineBreaks, withoutLineBreaks, repeatSelection, barcodes
    case toggleLineBreaks, toggleAppend, clearAppend, toggleSpeech, stopSpeech

    var id: String { rawValue }
    var title: String {
        switch self {
        case .precise: return L10n.text("精準框選")
        case .reread: return L10n.text("精準重讀上次圖片")
        case .video: return L10n.text("影片多畫面重讀")
        case .capture: return L10n.text("框選文字（依一般設定）")
        case .withLineBreaks: return L10n.text("框選文字 · 保留換行")
        case .withoutLineBreaks: return L10n.text("框選文字 · 合併成一行")
        case .repeatSelection: return L10n.text("重取上次選區")
        case .barcodes: return L10n.text("QR／條碼")
        case .toggleLineBreaks: return L10n.text("切換保留換行")
        case .toggleAppend: return L10n.text("切換累積剪貼簿")
        case .clearAppend: return L10n.text("清除累積文字")
        case .toggleSpeech: return L10n.text("切換擷取後朗讀")
        case .stopSpeech: return L10n.text("停止朗讀")
        }
    }
}

struct CaptureShortcut: Codable, Equatable {
    let key: UInt32
    let modifiers: UInt32
    let keyLabel: String

    private static let allowedModifiers = UInt32(cmdKey | controlKey | optionKey | shiftKey)
    var isValid: Bool {
        key <= 127 && modifiers & ~Self.allowedModifiers == 0
            && modifiers & UInt32(cmdKey | controlKey | optionKey) != 0
            && !keyLabel.isEmpty && keyLabel.count <= 12
    }
    var display: String {
        var value = ""
        if modifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        return value + keyLabel
    }
    func conflicts(with other: CaptureShortcut) -> Bool {
        key == other.key && modifiers == other.modifiers
    }

    static func from(_ event: NSEvent) -> CaptureShortcut? {
        var modifiers: UInt32 = 0
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let names: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc", 76: "⌤", 117: "⌦",
            115: "Home", 119: "End", 116: "Page ↑", 121: "Page ↓",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        let label = names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        let shortcut = CaptureShortcut(key: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label)
        return shortcut.isValid ? shortcut : nil
    }
}

@MainActor final class CaptureShortcutStore: ObservableObject {
    @Published private(set) var values: [String: CaptureShortcut]
    @Published var error = ""
    var registerChange: (CaptureShortcutAction, CaptureShortcut?) -> Bool = { _, _ in true }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "captureShortcuts"),
            let saved = try? JSONDecoder().decode([String: CaptureShortcut].self, from: data)
        {
            var restored: [String: CaptureShortcut] = [:]
            for action in CaptureShortcutAction.allCases {
                if let shortcut = saved[action.rawValue], shortcut.isValid,
                    !restored.values.contains(where: { $0.conflicts(with: shortcut) })
                {
                    restored[action.rawValue] = shortcut
                }
            }
            values = restored
        } else {
            let alternative = defaults.integer(forKey: "shortcutChoice") == 1
            values = [
                CaptureShortcutAction.capture.rawValue: CaptureShortcut(
                    key: UInt32(alternative ? kVK_ANSI_T : kVK_ANSI_2),
                    modifiers: UInt32(controlKey | (alternative ? optionKey : shiftKey)),
                    keyLabel: alternative ? "T" : "2"),
                CaptureShortcutAction.repeatSelection.rawValue: CaptureShortcut(
                    key: UInt32(kVK_ANSI_3), modifiers: UInt32(controlKey | shiftKey), keyLabel: "3"),
            ]
        }
    }

    subscript(action: CaptureShortcutAction) -> CaptureShortcut? { values[action.rawValue] }

    @discardableResult func update(_ action: CaptureShortcutAction, to shortcut: CaptureShortcut?) -> Bool {
        if let shortcut {
            guard shortcut.isValid else {
                error = L10n.text("請加入 Command、Control 或 Option 鍵。")
                return false
            }
            if let conflict = CaptureShortcutAction.allCases.first(where: {
                $0 != action && self[$0]?.conflicts(with: shortcut) == true
            }) {
                error = L10n.text(
                    "%1$@ 已用於「%2$@」。原有快捷鍵保持不變。", String(describing: shortcut.display),
                    String(describing: conflict.title))
                return false
            }
        }
        guard registerChange(action, shortcut) else {
            error = L10n.text(
                "%1$@ 已被其他 App 或系統佔用。原有快捷鍵保持不變。", String(describing: shortcut?.display ?? L10n.text("此快捷鍵")))
            return false
        }
        values[action.rawValue] = shortcut
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: "captureShortcuts") }
        error = ""
        return true
    }
}
