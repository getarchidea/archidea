import AppKit

/// Between a split's two pages: dragged, it shares the width differently; double-clicked, the halves are even again.
final class SplitDivider: NSView {
    static let width: CGFloat = 8

    /// The pointer's x in the page's area, while dragging.
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    var onReset: (() -> Void)?

    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var dragging = false { didSet { if dragging != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // A short grip in the middle, stronger under the pointer.
        let grip = NSRect(x: bounds.midX - 1.5, y: bounds.midY - 18, width: 3, height: 36)
        (hovering || dragging ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor.withAlphaComponent(0.5)).setFill()
        NSBezierPath(roundedRect: grip, xRadius: 1.5, yRadius: 1.5).fill()
    }

    /// The cursor comes from a tracking area, not cursor rects, which only work in the key window.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onReset?()
            return
        }
        dragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging, let superview else { return }
        NSCursor.resizeLeftRight.set()
        onDrag?(superview.convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        onEnd?()
    }
}

/// A thin ring round the side of a split that has the keyboard. It never takes a press.
final class PaneRing: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
        ring.lineWidth = 2
        NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
        ring.stroke()
    }
}

/// Over the page while a tab is dragged from the sidebar: let go over its left or right half, and the tab opens
/// there, beside the page in front.
final class SplitDropZone: NSView {
    /// Whether the dragged tab can go beside the page in front.
    var accepts: ((UUID) -> Bool)?
    /// The tab, and whether it goes on the left.
    var onDrop: ((UUID, Bool) -> Void)?

    private var side: Int? { didSet { if side != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        registerForDraggedTypes([SidebarList.itemType])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func dragged(_ info: NSDraggingInfo) -> UUID? {
        info.draggingPasteboard.string(forType: SidebarList.itemType).flatMap(UUID.init(uuidString:))
    }

    private func follow(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let id = dragged(info), accepts?(id) == true else {
            side = nil
            return []
        }
        side = convert(info.draggingLocation, from: nil).x < bounds.midX ? 0 : 1
        return .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { follow(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { follow(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { side = nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { side = nil }
        guard let id = dragged(sender), let side, accepts?(id) == true else { return false }
        onDrop?(id, side == 0)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let side else { return }
        let half = NSRect(x: side == 0 ? 0 : bounds.midX, y: 0, width: bounds.width / 2, height: bounds.height).insetBy(dx: 8, dy: 8)
        let shape = NSBezierPath(roundedRect: half, xRadius: 10, yRadius: 10)
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        shape.fill()
        shape.lineWidth = 2
        NSColor.controlAccentColor.withAlphaComponent(0.6).setStroke()
        shape.stroke()
    }
}
