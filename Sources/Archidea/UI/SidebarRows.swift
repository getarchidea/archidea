import AppKit
import ArchideaCore

class ChromeButton: NSButton, HoverTracking {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var hovering = false { didSet { needsDisplay = true } }

    init(symbol: String, tip: String, size: CGFloat = 14) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .regularSquare
        contentTintColor = .secondaryLabelColor
        toolTip = tip
        setButtonType(.momentaryChange)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.35 }
    }

    func setSymbol(_ symbol: String, size: CGFloat = 14) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .semibold))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = isUnderPointer }
    override func mouseMoved(with event: NSEvent) { if hovering != isUnderPointer { hovering.toggle() } }
    override func mouseExited(with event: NSEvent) { hovering = false }

    var isHovered: Bool { hovering }
    func refreshHover() { if hovering != isUnderPointer { hovering.toggle() } }

    override func draw(_ dirtyRect: NSRect) {
        if hovering && isEnabled {
            Theme.hover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}

final class SidebarOutline: NSOutlineView {
    /// See `SidebarScroll`: a swipe over the list goes to the window, which pages between spaces.
    override class var isCompatibleWithResponsiveScrolling: Bool { false }

    var onMiddleClick: ((Int) -> Void)?
    /// A drag left the list or ended (dropped or not): the drop indicator goes away.
    var onDragFinished: (() -> Void)?

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        onDragFinished?()
    }

    // NSOutlineView doesn't implement draggingEnded itself: calling super here raised "unrecognized selector".
    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDragFinished?()
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        super.concludeDragOperation(sender)
        onDragFinished?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Keys belong to the page, the command bar or a rename field; a focused list would type-select rows.
    override var acceptsFirstResponder: Bool { false }
    /// The row a context menu was opened on. Kept here instead of `clickedRow`, which also draws AppKit's blue outline.
    private(set) var contextRow = -1

    override func setFrameSize(_ newSize: NSSize) {
        let visible = enclosingScrollView?.contentSize
        super.setFrameSize(NSSize(width: visible?.width ?? newSize.width, height: max(newSize.height, visible?.height ?? 0)))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextRow = row(at: convert(event.locationInWindow, from: nil))
        return menu
    }

    override func otherMouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if event.buttonNumber == 2, row >= 0 { onMiddleClick?(row) } else { super.otherMouseDown(with: event) }
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        // Deeply nested folders stop indenting after a few levels, so titles keep their room in a narrow sidebar.
        let x = CGFloat(min(level(forRow: row), 3)) * indentationPerLevel
        frame.size.width += frame.origin.x - x
        frame.origin.x = x
        return frame
    }
}

final class SidebarRowView: NSTableRowView, HoverTracking {
    var hoverable = true

    /// Presses on the row belong to the list, which takes them even while the window isn't key yet.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
    var isActive = false { didSet { if isActive != oldValue { needsDisplay = true } } }
    private var hovering = false { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { refreshHover() }
    override func mouseMoved(with event: NSEvent) { refreshHover() }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshHover()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshHover()
    }

    var isHovered: Bool { hovering }

    func refreshHover() {
        let inside = hoverable && isUnderPointer
        if inside != hovering { hovering = inside }
    }

    /// The row view spans the table's row spacing too, so the card is inset to leave a gap between tabs.
    private var cardRect: NSRect { bounds.insetBy(dx: 8, dy: 2) }

    override func drawBackground(in dirtyRect: NSRect) {
        if isActive { return drawActiveCard() }
        guard hovering else { return }
        Theme.hover.setFill()
        NSBezierPath(roundedRect: cardRect, xRadius: 10, yRadius: 10).fill()
    }

    private func drawActiveCard() {
        let path = NSBezierPath(roundedRect: cardRect, xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.1)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        Theme.selectedCard.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override var isEmphasized: Bool { get { false } set {} }
}

final class SidebarCell: NSTableCellView, HoverTracking {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarCell")

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let closeButton = ChromeButton(symbol: "xmark", tip: L("tab.close"), size: 10)
    private let spinner = NSProgressIndicator()
    /// A live folder's tab not opened yet.
    private let unreadDot = NSView()
    /// How many of a live folder's tabs are new.
    private let count = NSTextField(labelWithString: "")
    private var closable = false
    private var hovering = false {
        didSet {
            closeButton.isHidden = !(hovering && closable)
            needsLayout = true
        }
    }
    var onClose: (() -> Void)?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 3
        icon.layer?.masksToBounds = true
        title.font = .systemFont(ofSize: 13, weight: .regular)
        title.lineBreakMode = .byTruncatingTail
        title.cell?.isScrollable = false
        title.isEditable = false
        title.focusRingType = .none
        title.drawsBackground = false
        closeButton.isHidden = true
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        unreadDot.wantsLayer = true
        unreadDot.layer?.cornerRadius = 3
        unreadDot.isHidden = true
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        count.textColor = .controlAccentColor
        count.alignment = .right
        count.isHidden = true
        imageView = icon
        textField = title
        [icon, spinner, unreadDot, title, count, closeButton].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(item: SidebarItem, icon image: NSImage?, loaded: Bool, loading: Bool, closable: Bool, tint: NSColor? = nil,
                   unread: Bool = false, count newCount: Int = 0) {
        if item.isFolder {
            icon.image = Self.folderImage(item.icon, open: item.expanded)
            icon.contentTintColor = .secondaryLabelColor
            icon.layer?.cornerRadius = 0
            title.stringValue = item.title
            title.font = .systemFont(ofSize: 13, weight: .medium)
        } else {
            icon.image = image ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            icon.contentTintColor = image == nil ? .tertiaryLabelColor : nil
            icon.layer?.cornerRadius = 3
            title.stringValue = item.displayTitle
            title.font = .systemFont(ofSize: 13, weight: .regular)
        }
        title.textColor = loaded ? .labelColor : .secondaryLabelColor
        icon.alphaValue = loaded ? 1 : 0.6
        // New in a live folder: a dot before it and its title in full, whether its page is loaded or not.
        unreadDot.isHidden = !unread
        unreadDot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        if unread {
            title.textColor = .labelColor
            title.font = .systemFont(ofSize: 13, weight: .semibold)
        }
        count.stringValue = newCount > 0 ? "\(newCount)" : ""
        count.isHidden = newCount == 0
        if loading && !item.isFolder { spinner.startAnimation(nil); icon.isHidden = true } else { spinner.stopAnimation(nil); icon.isHidden = false }
        self.closable = closable
        refreshHover()
        toolTip = item.isFolder ? nil : item.url
    }

    var isHovered: Bool { hovering }

    /// Hover from where the pointer actually is: a cell configured or moved under a still pointer gets no mouseEntered.
    func refreshHover() {
        let inside = isUnderPointer
        if inside != hovering { hovering = inside }
    }

    /// Only the close button and a name being edited take presses themselves. Everything else goes to the list:
    /// AppKit asks the view under the pointer whether a first click may act, and a plain label says no, so a click
    /// into a window that isn't key (just after switching apps) would only focus the window.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let hit, hit === closeButton || hit.isDescendant(of: closeButton) { return hit }
        if title.isEditable, let hit, hit === title || hit.isDescendant(of: title) { return hit }
        return nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshHover()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshHover()
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let left: CGFloat = 20
        icon.frame = NSRect(x: left, y: (h - 16) / 2, width: 16, height: 16)
        spinner.frame = icon.frame
        closeButton.frame = NSRect(x: bounds.width - 40, y: (h - 22) / 2, width: 22, height: 22)
        unreadDot.frame = NSRect(x: 8, y: (h - 6) / 2, width: 6, height: 6)
        count.frame = NSRect(x: bounds.width - 18 - 32, y: (h - 15) / 2, width: 32, height: 15)
        let right = !closeButton.isHidden ? bounds.width - 44 : !count.isHidden ? count.frame.minX - 4 : bounds.width - 18
        let textHeight = ceil(title.cell?.cellSize.height ?? 17)
        title.frame = NSRect(x: left + 26, y: floor((h - textHeight) / 2), width: max(0, right - left - 26), height: textHeight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = isUnderPointer }
    override func mouseMoved(with event: NSEvent) { if hovering != isUnderPointer { hovering.toggle() } }
    override func mouseExited(with event: NSEvent) { hovering = false }

    @objc private func closeTapped() { onClose?() }

    #if DRIFT_DEV
    var debugCloseTip: String { closeButton.toolTip ?? "-" }
    #endif

    /// An open pinned tab shows a minus: it closes but keeps its place. A closed pinned tab and a Today tab
    /// show a cross: it takes them out of the list.
    func setCloseStyle(pinned: Bool, loaded: Bool) {
        let unloads = pinned && loaded
        closeButton.setSymbol(unloads ? "minus" : "xmark", size: 10)
        closeButton.toolTip = unloads ? L("tab.unload.tip") : pinned ? L("tab.removePinned.tip") : L("tab.close")
    }

    func setFolderOpen(_ open: Bool, icon custom: String?) {
        icon.image = Self.folderImage(custom, open: open)
    }

    /// A folder's icon is an outline while it's open and filled while it's closed, whichever icon it has; an emoji
    /// stays as it is.
    private static func folderImage(_ custom: String?, open: Bool) -> NSImage? {
        Glyphs.image(custom ?? "folder", filled: !open, pointSize: 13) ?? Glyphs.image("folder", filled: !open, pointSize: 13)
    }

    func beginEditing(_ text: String) -> NSTextField {
        title.stringValue = text
        title.isEditable = true
        title.isSelectable = true
        title.drawsBackground = false
        title.backgroundColor = .clear
        title.cell?.isScrollable = true
        title.lineBreakMode = .byClipping
        closeButton.isHidden = true
        return title
    }

    func endEditing() {
        title.isEditable = false
        title.isSelectable = false
        title.cell?.isScrollable = false
        title.lineBreakMode = .byTruncatingTail
        title.delegate = nil
    }
}

/// A split's row: its tabs side by side, each with its icon, its title while there's room for one, and under the
/// pointer its own close button, with a hairline between each two. While the split is in front, the tab with the
/// keyboard reads in full and the others dimmer.
final class SplitCell: NSTableCellView, HoverTracking {
    static let identifier = NSUserInterfaceItemIdentifier("SplitCell")
    private static let gap: CGFloat = 9

    private var sides: [SplitSide] = []
    /// The side under the pointer, which shows its close button.
    private var hovered: Int? {
        didSet {
            guard hovered != oldValue else { return }
            for (index, side) in sides.enumerated() { side.showsClose = index == hovered }
        }
    }
    /// A side's close button was pressed: its place, left to right.
    var onClose: ((Int) -> Void)?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `focused`: the tab with the keyboard, while the split is in front. `closeTip` says what a side's close button
    /// does: in Today it closes the tab, among the pins it takes it out.
    func configure(split: SidebarItem, icons: [NSImage?], loaded: [Bool], loading: [Bool], focused: Int?, closeTip: String) {
        while sides.count < split.children.count {
            let index = sides.count
            let side = SplitSide()
            side.onClose = { [weak self] in self?.onClose?(index) }
            addSubview(side)
            sides.append(side)
        }
        while sides.count > split.children.count { sides.removeLast().removeFromSuperview() }
        for (index, side) in sides.enumerated() {
            side.configure(title: split.children[index].displayTitle, icon: icons[index], loaded: loaded[index],
                           loading: loading[index], strong: focused == nil || focused == index, closeTip: closeTip)
            side.showsClose = index == hovered
        }
        toolTip = split.children.map(\.url).joined(separator: "\n")
        needsLayout = true
        refreshHover()
    }

    /// Which side (0 on the left) a point in the cell is over.
    func side(at point: NSPoint) -> Int {
        sides.firstIndex { point.x < $0.frame.maxX + Self.gap / 2 } ?? max(0, sides.count - 1)
    }

    var isHovered: Bool { hovered != nil }

    func refreshHover() {
        guard let window, isUnderPointer else {
            hovered = nil
            return
        }
        hovered = side(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// Only the close buttons take presses; the rest goes to the list, which tells the sides apart.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let hit, sides.contains(where: { hit.isDescendant(of: $0.closeButton) }) { return hit }
        return nil
    }

    override func layout() {
        super.layout()
        let left: CGFloat = 20, right = bounds.width - 18
        let count = CGFloat(max(1, sides.count))
        let width = max(0, (right - left - Self.gap * (count - 1)) / count)
        for (index, side) in sides.enumerated() {
            side.frame = NSRect(x: left + CGFloat(index) * (width + Self.gap), y: 0, width: width, height: bounds.height)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        for side in sides.dropLast() {
            NSRect(x: side.frame.maxX + Self.gap / 2 - 0.5, y: (bounds.height - 16) / 2, width: 1, height: 16).fill()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshHover()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { refreshHover() }
    override func mouseMoved(with event: NSEvent) { refreshHover() }
    override func mouseExited(with event: NSEvent) { hovered = nil }
}

/// One side of a split's row: the tab's icon (a spinner while it loads), its title, and its close button while the
/// pointer is on it. Too narrow for a title (three or four tabs in a narrow sidebar), it shows the icon alone.
private final class SplitSide: NSView {
    let closeButton = ChromeButton(symbol: "xmark", tip: L("tab.close"), size: 10)
    var onClose: (() -> Void)?
    var showsClose = false {
        didSet {
            guard showsClose != oldValue else { return }
            closeButton.isHidden = !showsClose
            needsLayout = true
        }
    }

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 3
        icon.layer?.masksToBounds = true
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        title.cell?.isScrollable = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        closeButton.isHidden = true
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        for view in [icon, spinner, title, closeButton] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Only the close button takes presses.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let hit, hit.isDescendant(of: closeButton) { return hit }
        return nil
    }

    func configure(title text: String, icon image: NSImage?, loaded: Bool, loading: Bool, strong: Bool, closeTip: String) {
        icon.image = image ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        icon.contentTintColor = image == nil ? .tertiaryLabelColor : nil
        icon.alphaValue = loaded ? 1 : 0.6
        title.stringValue = text
        title.textColor = loaded && strong ? .labelColor : .secondaryLabelColor
        closeButton.toolTip = closeTip
        if loading { spinner.startAnimation(nil); icon.isHidden = true } else { spinner.stopAnimation(nil); icon.isHidden = false }
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 0, y: (h - 16) / 2, width: 16, height: 16)
        spinner.frame = icon.frame
        closeButton.frame = NSRect(x: bounds.width - 20, y: (h - 20) / 2, width: 20, height: 20)
        title.isHidden = bounds.width < 64
        let end = showsClose ? closeButton.frame.minX - 2 : bounds.width
        let textHeight = ceil(title.cell?.cellSize.height ?? 17)
        title.frame = NSRect(x: 22, y: floor((h - textHeight) / 2), width: max(0, end - 22), height: textHeight)
    }

    @objc private func closeTapped() { onClose?() }
}

final class DividerCell: NSTableCellView {
    var onClear: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === clear ? hit : nil
    }
    var showsClear = false { didSet { clear.isHidden = !showsClear } }
    var clearTip: String? { didSet { clear.toolTip = clearTip } }
    private let clear = FirstMouseButton(title: L("today.clear"), target: nil, action: nil)
    private let line = NSView()

    init() {
        super.init(frame: .zero)
        line.wantsLayer = true
        addSubview(line)
        clear.isBordered = false
        clear.font = .systemFont(ofSize: 11, weight: .medium)
        clear.contentTintColor = .tertiaryLabelColor
        clear.target = self
        clear.action = #selector(clearTapped)
        addSubview(clear)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let width = clear.isHidden ? 0 : clear.intrinsicContentSize.width + 8
        line.frame = NSRect(x: 20, y: bounds.midY, width: bounds.width - 40 - width, height: 1)
        line.layer?.backgroundColor = Theme.hairline.cgColor
        clear.frame = NSRect(x: bounds.width - 20 - width + 8, y: (bounds.height - 16) / 2, width: width - 8, height: 16)
    }

    @objc private func clearTapped() { onClear?() }
}

final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class NewTabCell: NSTableCellView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))!)
        icon.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: L("sidebar.newTab"))
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        icon.frame = NSRect(x: 20, y: 9, width: 16, height: 16)
        label.frame = NSRect(x: 46, y: 8, width: 200, height: 17)
        addSubview(icon)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// "Update ready" above the space bar: the new version and a restart button.
final class UpdateBanner: NSView {
    private let title = NSTextField(labelWithString: L("update.ready"))
    private let version = NSTextField(labelWithString: "")
    private let restart = NSButton(title: L("update.restart"), target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        let icon = NSImageView(image: NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))!)
        icon.contentTintColor = .controlAccentColor
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        version.font = .systemFont(ofSize: 11)
        version.textColor = .secondaryLabelColor
        restart.bezelStyle = .rounded
        restart.controlSize = .small
        restart.keyEquivalent = ""
        restart.target = self
        restart.action = #selector(restartTapped)
        let text = NSStackView(views: [title, version])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        for view in [icon, text, restart] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: restart.leadingAnchor, constant: -6),
            restart.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            restart.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(version number: String) {
        version.stringValue = "Archidea \(number)"
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.selectedCard.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }

    @objc private func restartTapped() { (NSApp.delegate as? AppDelegate)?.installUpdate() }
}

/// Where a dragged tab or group will land: an accent line at the drop's own nesting level, and a soft frame
/// around the group it goes into (brighter when dropping onto the group itself).
final class DropIndicator {
    private final class Mark: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private let line = Mark()
    private let group = Mark()

    init() {
        for view in [line, group] {
            view.wantsLayer = true
            view.layer?.cornerCurve = .continuous
        }
        line.layer?.cornerRadius = 1.5
        group.layer?.cornerRadius = 10
        group.layer?.borderWidth = 1.5
    }

    func show(line spot: (y: CGFloat, level: Int)?, group frame: NSRect?, onto: Bool, in outline: NSOutlineView) {
        let accent = NSColor.controlAccentColor
        if let frame {
            if group.superview !== outline { outline.addSubview(group) }
            group.frame = frame
            group.layer?.backgroundColor = accent.withAlphaComponent(onto ? 0.22 : 0.1).cgColor
            group.layer?.borderColor = accent.withAlphaComponent(onto ? 0.9 : 0.45).cgColor
            group.isHidden = false
        } else {
            group.isHidden = true
        }
        if let spot {
            if line.superview !== outline { outline.addSubview(line) }
            let x = 12 + CGFloat(spot.level) * outline.indentationPerLevel
            line.frame = NSRect(x: x, y: spot.y - 1.5, width: max(0, outline.bounds.width - x - 12), height: 3)
            line.layer?.backgroundColor = accent.cgColor
            line.isHidden = false
        } else {
            line.isHidden = true
        }
        // Above the rows.
        for view in [group, line] where !view.isHidden { outline.addSubview(view, positioned: .above, relativeTo: nil) }
    }

    func hide() {
        line.isHidden = true
        group.isHidden = true
    }
}
