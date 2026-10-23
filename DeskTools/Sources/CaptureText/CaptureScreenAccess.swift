import AppKit
import Combine
import DeskCore
import ScreenCaptureKit

@MainActor final class CaptureScreenAccess: ObservableObject {
    enum State: Equatable {
        case unverified, checking, allowed, denied
        case unavailable(String)
    }

    @Published private(set) var state: State = .unverified
    private let preflight: () -> Bool
    private let verify: () async throws -> Void
    private let openSettings: () -> Bool

    init(
        preflight: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
        verify: @escaping () async throws -> Void = {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        },
        openSettings: @escaping () -> Bool = {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    ) {
        self.preflight = preflight
        self.verify = verify
        self.openSettings = openSettings
        refresh()
    }

    var summary: String {
        switch state {
        case .unverified: return L10n.text("螢幕錄製：尚未確認；可按重新檢查")
        case .checking: return L10n.text("螢幕錄製：正在檢查…")
        case .allowed: return L10n.text("螢幕錄製：已允許")
        case .denied: return L10n.text("螢幕錄製：系統未授予目前版本權限")
        case .unavailable(let message): return L10n.text("錄屏暫不可用：%1$@", String(describing: message))
        }
    }

    static let recoveryMessage =
        L10n.text("macOS 未允許目前版本擷取畫面。請在螢幕與系統音訊錄製設定中重新加入 CaptureText；若已開啟，先關閉再開啟，並按系統提示重新開啟 App。")

    func refresh() {
        guard state != .checking else { return }
        if preflight() { state = .allowed }
        // A successful ScreenCaptureKit check is stronger than a stale legacy
        // preflight result. A confirmed denial also keeps its recovery actions
        // until a successful check or capture changes it.
    }

    func check() async {
        guard state != .checking else { return }
        state = .checking
        do {
            try await verify()
            state = .allowed
        } catch {
            if Self.isDenied(error) { state = .denied } else { state = .unavailable(error.localizedDescription) }
        }
    }

    func didObtainContent() { state = .allowed }

    @discardableResult func handle(_ error: Error) -> Bool {
        guard Self.isDenied(error) else { return false }
        state = .denied
        return true
    }

    func showSettings() {
        if !openSettings() {
            state = .unavailable(L10n.text("未能打開系統設定；請自行開啟隱私權與安全性 → 螢幕與系統音訊錄製。"))
        }
    }

    static func isDenied(_ error: Error) -> Bool {
        var value = error as NSError
        for _ in 0..<4 {
            if value.domain == SCStreamErrorDomain && value.code == -3801 { return true }
            guard let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            value = underlying
        }
        return false
    }
}
