import AppKit
import XCTest

@testable import CaptureText

final class CaptureDeviceMenuTests: XCTestCase {
    func testWindowKeepsTheImageReceiverAfterFocusReturnsToThePlainTextEditor() async throws {
        let domain = "CaptureDeviceMenuTests." + UUID().uuidString
        defer { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        try await MainActor.run {
            _ = NSApplication.shared
            let receiver = CaptureImportController(
                model: CaptureModel(defaults: try XCTUnwrap(UserDefaults(suiteName: domain))))
            let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
            editor.isRichText = false
            receiver.view = editor
            let window = CaptureImportWindow(
                contentRect: editor.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = receiver
            window.importReceiver = receiver
            defer { window.close() }
            XCTAssertTrue(window.makeFirstResponder(editor))
            for type in [NSPasteboard.PasteboardType.tiff, .png, .pdf] {
                XCTAssertTrue(
                    (window.validRequestor(forSendType: nil, returnType: type) as? CaptureImportController)
                        === receiver)
            }
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertTrue(receiver.responds(to: #selector(NSServicesMenuRequestor.readSelection(from:))))
        }
    }

    func testProgrammaticMenuRegistersTheServicesMenuWithoutLosingDeviceImport() async throws {
        let domain = "CaptureDeviceMenuTests." + UUID().uuidString
        defer { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        try await MainActor.run {
            let app = NSApplication.shared
            let originalMenu = app.mainMenu
            let originalServices = app.servicesMenu
            let originalPolicy = app.activationPolicy()
            defer {
                app.mainMenu = originalMenu
                app.servicesMenu = originalServices
                app.setActivationPolicy(originalPolicy)
            }
            let delegate = CaptureDelegate(
                model: CaptureModel(defaults: try XCTUnwrap(UserDefaults(suiteName: domain))),
                shortcuts: CaptureShortcutStore(defaults: try XCTUnwrap(UserDefaults(suiteName: domain))))
            delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
            let services = try XCTUnwrap(app.servicesMenu)
            XCTAssertTrue(
                app.mainMenu?.items.first?.submenu?.items.contains(where: { $0.submenu === services }) == true)
            let fileMenu = try XCTUnwrap(app.mainMenu?.items.first(where: { $0.title == "檔案" })?.submenu)
            XCTAssertTrue(fileMenu.items.contains(where: { $0.identifier == NSMenuItem.importFromDeviceIdentifier }))
        }
    }

    func testDeviceContextMenuUsesItsNativeOwnerAsTheContinuityRequestor() async throws {
        let domain = "CaptureDeviceMenuTests." + UUID().uuidString
        defer { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        try await MainActor.run {
            _ = NSApplication.shared
            let model = CaptureModel(defaults: try XCTUnwrap(UserDefaults(suiteName: domain)))
            let controller = CaptureImportController(model: model)
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
            let button = DeviceImportButton()
            button.frame = NSRect(x: 20, y: 30, width: 110, height: 24)
            view.addSubview(button)
            controller.view = view
            let window = NSWindow(
                contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            defer { window.close() }

            let menu = try XCTUnwrap(controller.contextualMenu(from: button))
            XCTAssertTrue(menu.allowsContextMenuPlugIns)
            XCTAssertTrue(window.firstResponder === button)
            for type in [NSPasteboard.PasteboardType.png, .tiff, .pdf, NSPasteboard.PasteboardType("public.image")] {
                XCTAssertTrue(
                    (button.validRequestor(forSendType: nil, returnType: type) as? CaptureImportController)
                        === controller)
                XCTAssertTrue(
                    (button.validRequestor(forSendType: .string, returnType: type) as? CaptureImportController)
                        === controller)
            }
            XCTAssertNil(button.validRequestor(forSendType: nil, returnType: .string) as? CaptureImportController)
            XCTAssertFalse(model.busy)
            XCTAssertEqual(menu.items.count, 1, "Unit tests must not manufacture discovered iPhones")
            XCTAssertNil(menu.items[0].action)
        }
    }

    func testMainFileMenuSelectsTheOCRReceiverBeforeAppKitUpdatesDeviceActions() async throws {
        let domain = "CaptureDeviceMenuTests." + UUID().uuidString
        defer { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        try await MainActor.run {
            _ = NSApplication.shared
            let controller = CaptureImportController(
                model: CaptureModel(defaults: try XCTUnwrap(UserDefaults(suiteName: domain))))
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
            let editor = NSTextView(frame: view.bounds)
            let button = DeviceImportButton()
            view.addSubview(editor)
            view.addSubview(button)
            controller.view = view
            let window = NSWindow(
                contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            defer { window.close() }
            XCTAssertTrue(window.makeFirstResponder(editor))

            let menu = NSMenu(title: "檔案")
            let item = CaptureImportController.mainMenuItem()
            menu.addItem(item)
            menu.delegate = controller
            controller.menuWillOpen(menu)
            XCTAssertEqual(item.identifier, NSMenuItem.importFromDeviceIdentifier)
            XCTAssertNil(item.action, "AppKit owns device discovery and its native actions")
            XCTAssertTrue(window.firstResponder === button)
            XCTAssertTrue(
                (button.validRequestor(forSendType: nil, returnType: .png) as? CaptureImportController) === controller)
        }
    }

    func testDetachedViewCannotPresentADeviceMenuAndImageTypesAreUnique() async throws {
        let domain = "CaptureDeviceMenuTests." + UUID().uuidString
        defer { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        try await MainActor.run {
            let controller = CaptureImportController(
                model: CaptureModel(defaults: try XCTUnwrap(UserDefaults(suiteName: domain))))
            XCTAssertNil(controller.contextualMenu(from: DeviceImportButton()))
            let types = CaptureImportController.supportedTypes
            XCTAssertEqual(Set(types).count, types.count)
            XCTAssertTrue(types.contains(.png))
            XCTAssertTrue(types.contains(.pdf))
            XCTAssertTrue(types.contains(NSPasteboard.PasteboardType("public.image")))
            XCTAssertTrue(
                (controller.validRequestor(forSendType: .string, returnType: .png) as? CaptureImportController)
                    === controller)
        }
    }
}
