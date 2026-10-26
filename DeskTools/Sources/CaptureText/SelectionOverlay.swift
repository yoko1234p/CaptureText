import AppKit
import CaptureCore
import DeskCore

@MainActor final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor final class SelectionView: NSView {
    // White arms with a dark outline stay visible over both light and dark text.
    static let selectionCursor: NSCursor = {
        let size = NSSize(width: 23, height: 23)
        let image = NSImage(size: size, flipped: false) { _ in
            let cross = NSBezierPath()
            cross.move(to: NSPoint(x: 3.5, y: 11.5))
            cross.line(to: NSPoint(x: 19.5, y: 11.5))
            cross.move(to: NSPoint(x: 11.5, y: 3.5))
            cross.line(to: NSPoint(x: 11.5, y: 19.5))
            NSColor.black.withAlphaComponent(0.95).setStroke()
            cross.lineWidth = 2
            cross.stroke()
            NSColor.white.setStroke()
            cross.lineWidth = 1
            cross.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 11.5, y: 11.5))
    }()

    let image: CGImage
    let onFinish: (CGImage?, CGRect?) -> Void
    private var origin: NSPoint?
    private var end: NSPoint?
    private var tracking: NSTrackingArea?
    var statusText = L10n.text("拖曳框選 · Esc 取消") {
        didSet {
            needsDisplay = true
            setAccessibilityValue(statusText)
        }
    }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(image: CGImage, size: NSSize, onFinish: @escaping (CGImage?, CGRect?) -> Void) {
        self.image = image
        self.onFinish = onFinish
        super.init(frame: NSRect(origin: .zero, size: size))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("capture.selection-area")
        setAccessibilityLabel(L10n.text("十字準星框選區"))
        setAccessibilityValue(statusText)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited, .mouseMoved],
            owner: self, userInfo: nil)
        tracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }

    func refreshSelectionCursor() {
        guard let window, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return }
        Self.selectionCursor.set()
    }

    override func cursorUpdate(with event: NSEvent) { Self.selectionCursor.set() }
    override func mouseEntered(with event: NSEvent) { Self.selectionCursor.set() }
    override func mouseMoved(with event: NSEvent) { Self.selectionCursor.set() }

    override func draw(_ dirtyRect: NSRect) {
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds)
        NSColor.black.withAlphaComponent(0.18).setFill()
        let shade = NSBezierPath(rect: bounds)
        if let rect = selection {
            shade.append(NSBezierPath(rect: rect))
            shade.windingRule = .evenOdd
        }
        shade.fill()
        if let rect = selection {
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 1
            path.stroke()
        }
        let label = statusText + L10n.text("   ·   ⌘L 換行  ⌘H 累積  ⌘S 朗讀")
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white,
        ]
        let width = (label as NSString).size(withAttributes: attrs).width
        let box = NSRect(
            x: max(12, (bounds.width - width - 32) / 2), y: 24, width: width + 32, height: 36)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12).fill()
        (label as NSString).draw(at: NSPoint(x: box.minX + 16, y: box.minY + 10), withAttributes: attrs)
    }

    private var selection: NSRect? {
        guard let origin, let end else { return nil }
        return CGRect(
            x: min(origin.x, end.x), y: min(origin.y, end.y), width: abs(origin.x - end.x),
            height: abs(origin.y - end.y))
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: Self.selectionCursor) }
    override func mouseDown(with event: NSEvent) {
        Self.selectionCursor.set()
        window?.makeKey()
        window?.makeFirstResponder(self)
        origin = convert(event.locationInWindow, from: nil)
        end = origin
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        Self.selectionCursor.set()
        end = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        end = convert(event.locationInWindow, from: nil)
        guard let selection,
            let rect = SelectionGeometry.pixelRect(
                selection: selection, bounds: bounds,
                imageWidth: image.width, imageHeight: image.height, paddingPoints: 4),
            let crop = image.cropping(to: rect)
        else {
            origin = nil
            end = nil
            needsDisplay = true
            return
        }
        onFinish(crop, rect)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish(nil, nil) } else { super.keyDown(with: event) }
    }
}
