import AppKit
import XCTest

@testable import CaptureText

final class CaptureMenuSelectionTests: XCTestCase {
    func testEveryStatusMenuCaptureCommandWaitsForTrackingToFinish() async throws {
        let domain = "CaptureMenuSelectionTests." + UUID().uuidString
        defer { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        try await MainActor.run {
            _ = NSApplication.shared
            let queue = CaptureMenuQueue()
            var requests: [CaptureRegionRequest] = []
            let launcher = CaptureMenuLauncher(schedule: { queue.schedule($0) }) { requests.append($0) }
            let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            let model = CaptureModel(defaults: defaults)
            model.hasLastSelection = true
            model.canReread = true
            let delegate = CaptureDelegate(
                model: model, shortcuts: CaptureShortcutStore(defaults: defaults), captureLauncher: launcher)
            let menu = NSMenu()
            delegate.menuNeedsUpdate(menu)
            let expected: [CaptureRegionRequest] = [
                .text, .withLineBreaks, .withoutLineBreaks, .repeatSelection, .barcodes, .precise, .reread, .video,
            ]
            for (index, request) in expected.enumerated() {
                delegate.menuWillOpen(menu)
                // Exercise the declared NSMenuItem target/selector, not a duplicate mapping.
                menu.performActionForItem(at: index)
                XCTAssertEqual(requests.count, index)
                XCTAssertTrue(queue.actions.isEmpty)
                delegate.menuDidClose(menu)
                XCTAssertEqual(requests.count, index, "Closing the menu is still inside AppKit's tracking callback")
                queue.drain()
                XCTAssertEqual(requests.last, request)
                XCTAssertEqual(requests.count, index + 1)
            }
            XCTAssertFalse(model.busy, "The test launcher must never snapshot the user's desktop")
        }
    }

    func testActionDeliveredAfterMenuDidCloseStillWaitsOneDefaultRunLoopTurn() async {
        await MainActor.run {
            let queue = CaptureMenuQueue()
            var requests: [CaptureRegionRequest] = []
            let launcher = CaptureMenuLauncher(schedule: { queue.schedule($0) }) { requests.append($0) }
            launcher.menuWillOpen()
            launcher.menuDidClose()
            launcher.request(.withoutLineBreaks, fromMenu: true)
            XCTAssertTrue(requests.isEmpty)
            queue.drain()
            XCTAssertEqual(requests, [.withoutLineBreaks])
            launcher.menuDidClose()
            queue.drain()
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testHotkeyStartsImmediatelyUnlessAStatusMenuIsTracking() async {
        await MainActor.run {
            let queue = CaptureMenuQueue()
            var requests: [CaptureRegionRequest] = []
            let launcher = CaptureMenuLauncher(schedule: { queue.schedule($0) }) { requests.append($0) }
            launcher.request(.text, fromMenu: false)
            XCTAssertEqual(requests, [.text])
            XCTAssertTrue(queue.actions.isEmpty)
            launcher.menuWillOpen()
            launcher.request(.barcodes, fromMenu: false)
            XCTAssertEqual(requests, [.text])
            launcher.menuDidClose()
            queue.drain()
            XCTAssertEqual(requests, [.text, .barcodes])
        }
    }

    func testReopenedMenuAndCancelledPendingRequestCannotStartAnObsoleteCapture() async {
        await MainActor.run {
            let queue = CaptureMenuQueue()
            var requests: [CaptureRegionRequest] = []
            let launcher = CaptureMenuLauncher(schedule: { queue.schedule($0) }) { requests.append($0) }
            launcher.request(.text, fromMenu: true)
            launcher.menuWillOpen()
            queue.drain()
            XCTAssertTrue(requests.isEmpty)
            launcher.request(.withLineBreaks, fromMenu: true)
            launcher.menuDidClose()
            launcher.cancelPending()
            launcher.request(.repeatSelection, fromMenu: true)
            queue.drain()
            XCTAssertEqual(requests, [.repeatSelection])
            queue.drain()
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testNativeDeviceMenuIsNeverOpenedInsideStatusMenuTracking() async {
        await MainActor.run {
            let queue = CaptureMenuQueue()
            var nativeMenusOpened = 0
            let launcher = CaptureMenuLauncher(schedule: { queue.schedule($0) }) { _ in XCTFail("Unexpected capture") }
            launcher.menuWillOpen()
            launcher.perform(fromMenu: true) { nativeMenusOpened += 1 }
            XCTAssertEqual(nativeMenusOpened, 0)
            launcher.menuDidClose()
            XCTAssertEqual(nativeMenusOpened, 0)
            queue.drain()
            XCTAssertEqual(nativeMenusOpened, 1)
        }
    }

    func testCrosshairTrackingWorksOnNonKeyScreensAndSurvivesViewResize() async throws {
        try await MainActor.run {
            let view = SelectionView(image: try Self.image(), size: NSSize(width: 200, height: 100)) { _, _ in }
            view.updateTrackingAreas()
            let tracking = try XCTUnwrap(view.trackingAreas.first)
            XCTAssertTrue(tracking.options.contains(.activeAlways))
            XCTAssertTrue(tracking.options.contains(.cursorUpdate))
            XCTAssertTrue(tracking.options.contains(.mouseMoved))
            XCTAssertFalse(tracking.options.contains(.activeInKeyWindow))
            view.frame.size = NSSize(width: 500, height: 300)
            view.updateTrackingAreas()
            XCTAssertEqual(view.trackingAreas.count, 1)
            XCTAssertTrue(try XCTUnwrap(view.trackingAreas.first).options.contains(.inVisibleRect))
            XCTAssertFalse(view.mouseDownCanMoveWindow)
            XCTAssertTrue(view.acceptsFirstMouse(for: nil))
        }
    }

    func testNativeReverseDragUsesTheCrosshairPositionAndCropsRetinaPixels() async throws {
        try await MainActor.run {
            let previousCursor = NSCursor.current
            defer { previousCursor.set() }
            var deliveredRect: CGRect?
            var deliveredSize: CGSize?
            let view = SelectionView(image: try Self.image(), size: NSSize(width: 200, height: 100)) { image, rect in
                deliveredRect = rect
                deliveredSize = image.map { CGSize(width: $0.width, height: $0.height) }
            }
            view.mouseDown(with: try Self.mouse(.leftMouseDown, at: NSPoint(x: 80, y: 60)))
            view.mouseDragged(with: try Self.mouse(.leftMouseDragged, at: NSPoint(x: 20, y: 30)))
            view.mouseUp(with: try Self.mouse(.leftMouseUp, at: NSPoint(x: 20, y: 30)))
            XCTAssertEqual(deliveredRect, CGRect(x: 32, y: 72, width: 136, height: 76))
            XCTAssertEqual(deliveredSize, CGSize(width: 136, height: 76))
        }
    }

    func testTinyClickKeepsSelectionOpenAndEscapeCancelsWithoutDeliveringAnImage() async throws {
        try await MainActor.run {
            let previousCursor = NSCursor.current
            defer { previousCursor.set() }
            var cancellations = 0
            let view = SelectionView(image: try Self.image(), size: NSSize(width: 200, height: 100)) { image, rect in
                XCTAssertNil(image)
                XCTAssertNil(rect)
                cancellations += 1
            }
            view.mouseDown(with: try Self.mouse(.leftMouseDown, at: NSPoint(x: 80, y: 60)))
            view.mouseUp(with: try Self.mouse(.leftMouseUp, at: NSPoint(x: 81, y: 61)))
            XCTAssertEqual(cancellations, 0)
            let escape = try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false,
                    keyCode: 53))
            view.keyDown(with: escape)
            XCTAssertEqual(cancellations, 1)
        }
    }

    private static func image() throws -> CGImage {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 1600,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        return try XCTUnwrap(context.makeImage())
    }

    private static func mouse(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
}

@MainActor private final class CaptureMenuQueue {
    var actions: [@MainActor @Sendable () -> Void] = []
    func schedule(_ action: @escaping @MainActor @Sendable () -> Void) { actions.append(action) }
    func drain() {
        let pending = actions
        actions.removeAll()
        for action in pending { action() }
    }
}
