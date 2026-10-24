import AppKit
import ArchideaCore

/// The icon picker for folders and spaces, in a popover: SF Symbols with a search, or emoji: a grid of common ones,
/// and any other typed in, pasted or picked from the Character Viewer.
final class IconPicker: NSViewController, NSSearchFieldDelegate {
    private let symbols: [String]
    private let emoji: [String]
    private let selected: String
    private let tint: NSColor
    private let onPick: (String) -> Void
    private var popover: NSPopover?

    private let tabs = NSSegmentedControl(labels: [L("icons.symbols"), L("icons.emoji")], trackingMode: .selectOne,
                                          target: nil, action: nil)
    private let search = NSSearchField()
    private let anyEmoji = NSTextField()
    private let allEmoji = NSButton()
    private let scroll = NSScrollView()
    private let grid = IconGrid()

    private static let columns = 8
    private static let cell: CGFloat = 34
    private static let padding: CGFloat = 10
    private static let gridHeight: CGFloat = 238

    /// `symbols` the picker may offer; those this Mac lacks are left out.
    init(symbols: [String] = SpaceStyle.pickerSymbols, emoji: [String] = SpaceStyle.pickerEmoji, selected: String, tint: NSColor,
         onPick: @escaping (String) -> Void) {
        self.symbols = symbols.filter(Glyphs.exists)
        self.emoji = emoji
        self.selected = selected
        self.tint = tint
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let p = Self.padding
        let width = CGFloat(Self.columns) * Self.cell + p * 2
        let height = p + 24 + 8 + 24 + 8 + Self.gridHeight + p
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        tabs.frame = NSRect(x: p, y: height - p - 24, width: width - p * 2, height: 24)
        tabs.segmentDistribution = .fillEqually
        tabs.selectedSegment = Glyph.isEmoji(selected) ? 1 : 0
        tabs.target = self
        tabs.action = #selector(tabChanged)

        let fieldY = tabs.frame.minY - 8 - 24
        search.frame = NSRect(x: p, y: fieldY, width: width - p * 2, height: 24)
        search.placeholderString = L("icons.search")
        search.delegate = self
        anyEmoji.frame = NSRect(x: p, y: fieldY, width: width - p * 2 - 32, height: 24)
        anyEmoji.placeholderString = L("icons.anyEmoji")
        anyEmoji.delegate = self
        allEmoji.frame = NSRect(x: width - p - 28, y: fieldY, width: 28, height: 24)
        allEmoji.isBordered = false
        allEmoji.image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: L("icons.allEmoji"))
        allEmoji.toolTip = L("icons.allEmoji")
        allEmoji.target = self
        allEmoji.action = #selector(showCharacterViewer)

        scroll.frame = NSRect(x: p - 2, y: p, width: width - (p - 2) * 2, height: Self.gridHeight)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = grid
        [tabs, search, anyEmoji, allEmoji, scroll].forEach(container.addSubview)
        view = container
        preferredContentSize = container.frame.size
        showTab()
    }

    func present(relativeTo rect: NSRect, of view: NSView, edge: NSRectEdge) {
        let popover = NSPopover()
        popover.contentViewController = self
        popover.behavior = .transient
        popover.animates = true
        self.popover = popover
        popover.show(relativeTo: rect, of: view, preferredEdge: edge)
    }

    private var showsEmoji: Bool { tabs.selectedSegment == 1 }

    @objc private func tabChanged() { showTab() }

    private func showTab() {
        search.isHidden = showsEmoji
        anyEmoji.isHidden = !showsEmoji
        allEmoji.isHidden = !showsEmoji
        if showsEmoji {
            fill(emoji)
        } else {
            filterSymbols()
        }
    }

    private func filterSymbols() {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        fill(query.isEmpty ? symbols : symbols.filter { $0.replacingOccurrences(of: ".", with: " ").contains(query) })
    }

    private func fill(_ values: [String]) {
        grid.subviews.forEach { $0.removeFromSuperview() }
        let rows = (values.count + Self.columns - 1) / Self.columns
        grid.frame = NSRect(x: 0, y: 0, width: CGFloat(Self.columns) * Self.cell, height: max(Self.gridHeight, CGFloat(rows) * Self.cell))
        for (index, value) in values.enumerated() {
            let cell = IconCell(value: value, tint: tint, selected: value == selected)
            cell.frame = NSRect(x: CGFloat(index % Self.columns) * Self.cell, y: CGFloat(index / Self.columns) * Self.cell,
                                width: Self.cell, height: Self.cell)
            cell.onClick = { [weak self] in self?.pick(value) }
            grid.addSubview(cell)
        }
        grid.scroll(.zero)
    }

    private func pick(_ value: String) {
        onPick(value)
        popover?.close()
    }

    /// The system's Character Viewer types into the emoji field. It's a panel of its own, so the popover stops closing
    /// on clicks elsewhere while it's open.
    @objc private func showCharacterViewer() {
        popover?.behavior = .semitransient
        view.window?.makeFirstResponder(anyEmoji)
        NSApp.orderFrontCharacterPalette(nil)
    }

    func controlTextDidChange(_ obj: Notification) {
        let field = obj.object as? NSObject
        if field === search {
            filterSymbols()
        } else if field === anyEmoji, let last = anyEmoji.stringValue.last.map({ String($0) }), Glyph.isEmoji(last) {
            pick(last)
        }
    }
}

/// The picker's grid, laid out top down.
private final class IconGrid: NSView {
    override var isFlipped: Bool { true }
}

private final class IconCell: NSView {
    var onClick: (() -> Void)?
    private let icon = NSImageView()
    private let tint: NSColor
    private let selected: Bool
    private var hovering = false { didSet { needsDisplay = true } }

    init(value: String, tint: NSColor, selected: Bool) {
        self.tint = tint
        self.selected = selected
        super.init(frame: .zero)
        icon.image = Glyphs.image(value, filled: selected, pointSize: 15)
        icon.contentTintColor = selected ? tint : .secondaryLabelColor
        addSubview(icon)
        toolTip = Glyph.isEmoji(value) ? nil : value
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        icon.frame = bounds.insetBy(dx: 7, dy: 7)
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
