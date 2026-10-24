import AppKit

/// A view that takes sidebar items dropped on it and highlights while one hovers.
class SidebarDropView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var dropTarget: ((NSDraggingInfo) -> Bool)? {
        didSet { registerForDraggedTypes(dropTarget == nil ? [] : [SidebarView.itemType]) }
    }
    var dropHovering = false { didSet { needsDisplay = true } }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropHovering = true
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropHovering = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropHovering = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHovering = false
        return dropTarget?(sender) ?? false
    }
}

final class SpaceHeader: SidebarDropView {
    var onClick: (() -> Void)?
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)!
        .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))!)
    private var hovering = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        icon.imageScaling = .scaleNone
        icon.imageAlignment = .alignCenter
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.alphaValue = 0
        [icon, name, chevron].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ space: Space) {
        icon.image = NSImage(systemSymbolName: "\(space.symbol).fill", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: space.symbol, accessibilityDescription: nil)
        icon.contentTintColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.stringValue = space.name
        needsLayout = true
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 6, y: 0, width: 20, height: bounds.height)
        let width = min(ceil(name.attributedStringValue.size().width) + 4, bounds.width - 60)
        name.frame = NSRect(x: 32, y: (bounds.height - 17) / 2, width: width, height: 17)
        chevron.frame = NSRect(x: name.frame.maxX + 6, y: (bounds.height - 10) / 2, width: 10, height: 10)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setHover(isUnderPointer) }
    override func mouseMoved(with event: NSEvent) { if hovering != isUnderPointer { setHover(!hovering) } }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    private func setHover(_ on: Bool) {
        hovering = on
        chevron.animator().alphaValue = on ? 1 : 0
    }

    override func draw(_ dirtyRect: NSRect) {
        if dropHovering {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
            return
        }
        guard hovering else { return }
        Theme.hover.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

final class SpaceButton: SidebarDropView {
    static let fullWidth: CGFloat = 30
    static let compactWidth: CGFloat = 16

    let space: Space
    let current: Bool
    var onClick: (() -> Void)?
    private let icon = NSImageView()
    private var widthConstraint: NSLayoutConstraint?
    private var hovering = false { didSet { needsDisplay = true } }

    /// A dot instead of the icon, when there are more spaces than room for their icons.
    var compact = false {
        didSet {
            guard compact != oldValue else { return }
            icon.isHidden = compact
            widthConstraint?.constant = compact ? Self.compactWidth : Self.fullWidth
            needsDisplay = true
        }
    }

    init(space: Space, current: Bool) {
        self.space = space
        self.current = current
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 28))
        let symbol = current ? "\(space.symbol).fill" : space.symbol
        icon.image = (NSImage(systemSymbolName: symbol, accessibilityDescription: space.name)
            ?? NSImage(systemSymbolName: space.symbol, accessibilityDescription: space.name))?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        // Neutral label colours follow the sidebar's light or dark scheme, so the icon never melts into the tint.
        icon.contentTintColor = current ? .labelColor : .secondaryLabelColor
        icon.imageScaling = .scaleNone
        icon.imageAlignment = .alignCenter
        addSubview(icon)
        toolTip = space.name
        widthConstraint = widthAnchor.constraint(equalToConstant: Self.fullWidth)
        widthConstraint?.isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        icon.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = isUnderPointer }
    override func mouseMoved(with event: NSEvent) { if hovering != isUnderPointer { hovering.toggle() } }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        if dropHovering {
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            pill.fill()
        } else if current {
            Theme.selectedCard.setFill()
            pill.fill()
        } else if hovering {
            Theme.hover.setFill()
            pill.fill()
        }
        if compact {
            let size: CGFloat = current ? 7 : 5
            (current ? NSColor.labelColor : NSColor.secondaryLabelColor).setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size)).fill()
        }
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// The sideways strip of space buttons: no scroll bar, and a mouse wheel's vertical turns move it sideways too.
final class SpaceStrip: NSScrollView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        hasHorizontalScroller = false
        hasVerticalScroller = false
        verticalScrollElasticity = .none
    }

    required init?(coder: NSCoder) { fatalError() }

    override func scrollWheel(with event: NSEvent) {
        guard let document = documentView, document.frame.width > bounds.width else { return super.scrollWheel(with: event) }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        let step = event.hasPreciseScrollingDeltas ? delta : delta * 12
        let x = min(max(0, contentView.bounds.minX - step), document.frame.width - bounds.width)
        contentView.scroll(to: NSPoint(x: x, y: 0))
        reflectScrolledClipView(contentView)
    }
}
