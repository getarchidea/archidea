import AppKit

/// A grid of SF Symbols in a popover, for folder and space icons.
final class IconPicker: NSViewController {
    private let symbols: [String]
    private let selected: String
    private let tint: NSColor
    private let onPick: (String) -> Void
    private var popover: NSPopover?

    private static let columns = 6
    private static let cell: CGFloat = 34

    init(symbols: [String], selected: String, tint: NSColor, onPick: @escaping (String) -> Void) {
        self.symbols = symbols
        self.selected = selected
        self.tint = tint
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let rows = (symbols.count + Self.columns - 1) / Self.columns
        let padding: CGFloat = 10
        let size = NSSize(width: CGFloat(Self.columns) * Self.cell + padding * 2, height: CGFloat(rows) * Self.cell + padding * 2)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        for (index, symbol) in symbols.enumerated() {
            let column = index % Self.columns, row = index / Self.columns
            let button = IconCell(symbol: symbol, tint: tint, selected: symbol == selected)
            button.frame = NSRect(x: padding + CGFloat(column) * Self.cell,
                                  y: size.height - padding - CGFloat(row + 1) * Self.cell,
                                  width: Self.cell, height: Self.cell)
            button.onClick = { [weak self] in
                self?.onPick(symbol)
                self?.popover?.close()
            }
            container.addSubview(button)
        }
        view = container
        preferredContentSize = size
    }

    func present(relativeTo rect: NSRect, of view: NSView, edge: NSRectEdge) {
        let popover = NSPopover()
        popover.contentViewController = self
        popover.behavior = .transient
        popover.animates = true
        self.popover = popover
        popover.show(relativeTo: rect, of: view, preferredEdge: edge)
    }
}

private final class IconCell: NSView {
    var onClick: (() -> Void)?
    private let icon = NSImageView()
    private let tint: NSColor
    private let selected: Bool
    private var hovering = false { didSet { needsDisplay = true } }

    init(symbol: String, tint: NSColor, selected: Bool) {
        self.tint = tint
        self.selected = selected
        super.init(frame: .zero)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        icon.contentTintColor = selected ? tint : .secondaryLabelColor
        addSubview(icon)
        toolTip = symbol
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        icon.frame = bounds.insetBy(dx: 8, dy: 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 2)
        if selected {
            tint.withAlphaComponent(0.2).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        } else if hovering {
            Theme.hover.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
