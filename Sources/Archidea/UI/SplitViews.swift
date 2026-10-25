import AppKit
import ArchideaCore

/// One page of a split, on a card of its own: rounded and edged like the single page, which it clips to its corners,
/// with the window showing between the cards.
final class PaneCard: NSView {
    static let radius: CGFloat = 10

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = Self.radius
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.page.cgColor
        layer?.borderColor = Theme.hairline.cgColor
        layer?.borderWidth = 1
    }
}

/// The gap between two cards of a split. Dragged, it shares the width between those two pages differently;
/// double-clicked, every page of the split has an even share again. A grip shows while the pointer is on it.
final class SplitDivider: NSView {
    /// Between two cards, as wide as the window's margin round them.
    static let gap = RootView.gap

    private static let grip = Theme.dynamic(dark: .white.withAlphaComponent(0.3), light: .black.withAlphaComponent(0.22))
    private static let gripHeld = Theme.dynamic(dark: .white.withAlphaComponent(0.55), light: .black.withAlphaComponent(0.4))

    /// The pointer's x in the pages' area, while dragging.
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
        guard hovering || dragging else { return }
        let grip = NSRect(x: bounds.midX - 2, y: bounds.midY - 20, width: 4, height: 40)
        (dragging ? Self.gripHeld : Self.grip).setFill()
        NSBezierPath(roundedRect: grip, xRadius: 2, yRadius: 2).fill()
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

/// An outline just outside the card of the split's page that has the keyboard. It never takes a press.
final class PaneRing: NSView {
    /// How far out from the card the ring's frame reaches: a point of gap, then the line.
    static let outset: CGFloat = 3

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        // Round the card's corners at the line's distance from them, so the gap stays even.
        let radius = PaneCard.radius + Self.outset - 1
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
        ring.lineWidth = 2
        NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
        ring.stroke()
    }
}

/// Over the pages while a tab is dragged from the sidebar: a card on the half of the page under the pointer shows
/// where the tab would open. Let go, it opens there, beside that page.
final class SplitDropZone: NSView {
    /// The pages' frames, left to right: the split's, or the one page in front.
    var panes: (() -> [NSRect])?
    /// Whether the dragged tab can go beside the pages in front.
    var accepts: ((UUID) -> Bool)?
    /// The tab, the page it goes beside (by its place, left to right), and whether it goes on that page's left.
    var onDrop: ((UUID, Int, Bool) -> Void)?

    private let card = DropCard()
    private var target: (pane: Int, before: Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        card.alphaValue = 0
        addSubview(card)
        registerForDraggedTypes([SidebarList.itemType])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Nothing shown, for the next drag.
    func reset() {
        target = nil
        card.alphaValue = 0
    }

    private func dragged(_ info: NSDraggingInfo) -> UUID? {
        info.draggingPasteboard.string(forType: SidebarList.itemType).flatMap(UUID.init(uuidString:))
    }

    private func follow(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let id = dragged(info), accepts?(id) == true, let frames = panes?(), !frames.isEmpty else {
            aim(at: nil, in: [])
            return []
        }
        let x = convert(info.draggingLocation, from: nil).x
        // The page under the pointer; over a gap, the one to its left.
        let index = frames.firstIndex { x < $0.maxX } ?? frames.count - 1
        aim(at: (index, x < frames[index].midX), in: frames)
        return .move
    }

    private func aim(at next: (pane: Int, before: Bool)?, in frames: [NSRect]) {
        guard next?.pane != target?.pane || next?.before != target?.before else { return }
        let appearing = target == nil
        target = next
        guard let next else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                card.animator().alphaValue = 0
            }
            return
        }
        let page = frames[next.pane]
        let half = NSRect(x: next.before ? page.minX : page.midX, y: page.minY, width: page.width / 2, height: page.height)
            .insetBy(dx: 6, dy: 6)
        card.before = next.before
        if appearing { card.frame = half }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
            card.animator().frame = half
            card.animator().alphaValue = 1
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { follow(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { follow(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { aim(at: nil, in: []) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { reset() }
        guard let id = dragged(sender), let target, accepts?(id) == true else { return false }
        onDrop?(id, target.pane, target.before)
        return true
    }
}

/// Where a dragged tab would open: a dashed card saying which side of the page it goes on. Drawn with layers, set
/// in `updateLayer` for the light or dark look.
private final class DropCard: NSView {
    private static let fill = Theme.dynamic(dark: NSColor(srgbRed: 0.15, green: 0.16, blue: 0.17, alpha: 0.96),
                                            light: NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 0.96))
    private static let edge = Theme.dynamic(dark: .white.withAlphaComponent(0.26), light: .black.withAlphaComponent(0.2))
    private static let radius: CGFloat = 14

    var before = true {
        didSet { if before != oldValue { update() } }
    }

    private let dashes = CAShapeLayer()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.radius
        layer?.cornerCurve = .continuous
        dashes.fillColor = nil
        dashes.lineWidth = 1.5
        dashes.lineDashPattern = [6, 4]
        layer?.addSublayer(dashes)
        icon.contentTintColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        addSubview(icon)
        addSubview(label)
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.backgroundColor = Self.fill.cgColor
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: -2)
        dashes.strokeColor = Self.edge.cgColor
    }

    private func update() {
        icon.image = NSImage(systemSymbolName: before ? "rectangle.lefthalf.filled" : "rectangle.righthalf.filled",
                             accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        label.stringValue = before ? L("split.addLeft") : L("split.addRight")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset = dashes.lineWidth / 2
        dashes.frame = bounds
        dashes.path = CGPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), cornerWidth: Self.radius - inset,
                             cornerHeight: Self.radius - inset, transform: nil)
        let labelHeight = ceil(label.cell?.cellSize.height ?? 17)
        let top = bounds.midY + (18 + 8 + labelHeight) / 2
        icon.frame = NSRect(x: bounds.midX - 9, y: top - 18, width: 18, height: 18)
        label.frame = NSRect(x: 8, y: top - 18 - 8 - labelHeight, width: max(0, bounds.width - 16), height: labelHeight)
    }
}
