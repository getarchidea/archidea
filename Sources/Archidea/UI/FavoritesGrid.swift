import AppKit
import ArchideaCore

/// The favourites, the same in every space: tabs as tiles above the pins, three to a row, every row as wide as the
/// sidebar (four make a row of three and a row of one as wide as the three). A tile shows the site's icon, lit while
/// it's the tab in front. A click opens it, a drag moves it among the tiles or out to the list, and a tab dragged here
/// from the list becomes one. With no favourites yet the grid takes no room; while a tab is dragged it lies over the
/// space's name, unseen, and shows where to drop only once the tab is over it.
final class FavoritesGrid: NSView {
    static let columns = 3
    static let tileHeight: CGFloat = 44
    static let gap: CGFloat = 8

    weak var delegate: SidebarViewDelegate?
    /// The grid's height changed (tiles came or went, a drag began or ended): the sidebar lays out again.
    var onResize: (() -> Void)?
    /// A tab dragged over the empty grid: what it lies over (the space's name) steps aside for the drop spot.
    var onDropSpot: ((Bool) -> Void)?

    private var space: Space?
    private var selectedID: UUID?
    private var tiles: [FavoriteTile] = []
    private let placeholder = FavoritesPlaceholder()
    /// Where a tab dragged over the grid would go: before the tile at this index (the count: after the last).
    private var dropIndex: Int? {
        didSet {
            guard dropIndex != oldValue else { return }
            needsLayout = true
            if tiles.isEmpty, (dropIndex == nil) != (oldValue == nil) { onDropSpot?(dropIndex != nil) }
        }
    }

    /// A row of the list is being dragged: an empty grid lies ready over the space's name.
    var dragging = false {
        didSet {
            guard dragging != oldValue else { return }
            if !dragging { dropIndex = nil }
            if tiles.isEmpty { onResize?() }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        placeholder.isHidden = true
        addSubview(placeholder)
        registerForDraggedTypes([SidebarList.itemType])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var items: [SidebarItem] { space?.favorites.children ?? [] }

    /// The favourites as `space` shows them, with `selected` the window's tab in front.
    func show(_ space: Space, selected: UUID?) {
        let count = tiles.count
        self.space = space
        selectedID = selected
        while tiles.count < items.count {
            let tile = FavoriteTile()
            tile.grid = self
            addSubview(tile)
            tiles.append(tile)
        }
        while tiles.count > items.count { tiles.removeLast().removeFromSuperview() }
        for (tile, item) in zip(tiles, items) { configure(tile, for: item) }
        needsLayout = true
        if tiles.count != count { onResize?() }
    }

    /// One favourite changed (its icon, its page loading, going to sleep or playing sound).
    func reload(_ item: SidebarItem) {
        guard let index = items.firstIndex(where: { $0 === item }), tiles.indices.contains(index) else { return }
        configure(tiles[index], for: item)
    }

    func reflectSelection(_ selected: UUID?) {
        selectedID = selected
        for (tile, item) in zip(tiles, items) { tile.isActive = item.id == selected }
    }

    private func configure(_ tile: FavoriteTile, for item: SidebarItem) {
        tile.item = item
        tile.icon = delegate?.sidebarFavicon(for: item)
        tile.loaded = delegate?.sidebarIsLoaded(item) ?? false
        tile.sound.tabSound = delegate?.sidebarSound(item) ?? .silent
        tile.isActive = item.id == selectedID
        tile.toolTip = item.displayTitle
    }

    // MARK: layout

    /// The rows: three tiles each, the last holding what's left.
    private static func rows(_ count: Int) -> [Range<Int>] {
        stride(from: 0, to: count, by: columns).map { $0..<min($0 + columns, count) }
    }

    /// As tall as its rows; nothing while there are no favourites (a drag doesn't make room: the list stays put).
    var contentHeight: CGFloat {
        let rows = CGFloat(Self.rows(tiles.count).count)
        return rows == 0 ? 0 : rows * Self.tileHeight + (rows - 1) * Self.gap
    }

    private func frames(in width: CGFloat) -> [NSRect] {
        Self.rows(tiles.count).enumerated().flatMap { row, range -> [NSRect] in
            let y = CGFloat(row) * (Self.tileHeight + Self.gap)
            let tileWidth = (width - Self.gap * CGFloat(range.count - 1)) / CGFloat(range.count)
            return range.map { index in
                let column = CGFloat(index - range.lowerBound)
                return NSRect(x: column * (tileWidth + Self.gap), y: y, width: tileWidth, height: Self.tileHeight)
            }
        }
    }

    override func layout() {
        super.layout()
        for (tile, frame) in zip(tiles, frames(in: bounds.width)) { tile.frame = frame }
        placeholder.isHidden = !(dragging && tiles.isEmpty && dropIndex != nil)
        placeholder.frame = tiles.isEmpty ? bounds : NSRect(x: 0, y: 0, width: bounds.width, height: Self.tileHeight)
        placeholder.highlighted = dropIndex != nil
        for (index, tile) in tiles.enumerated() {
            tile.markedBefore = dropIndex == index
            tile.markedAfter = dropIndex == tiles.count && index == tiles.count - 1
        }
    }

    // MARK: taking a tab

    /// The tab being dragged, if it's one the grid takes: a tab of its own, not a folder or a split's side.
    private func dragged(_ info: NSDraggingInfo) -> SidebarItem? {
        guard let id = info.draggingPasteboard.string(forType: SidebarList.itemType).flatMap(UUID.init(uuidString:)),
              let space, let item = space.find(id), item.isTab, space.split(containing: item) == nil else { return nil }
        return item
    }

    private func follow(_ info: NSDraggingInfo) -> NSDragOperation {
        guard dragged(info) != nil else {
            dropIndex = nil
            return []
        }
        let point = convert(info.draggingLocation, from: nil)
        let frames = frames(in: bounds.width)
        if let hit = frames.firstIndex(where: { $0.insetBy(dx: -Self.gap / 2, dy: -Self.gap / 2).contains(point) }) {
            dropIndex = point.x < frames[hit].midX ? hit : hit + 1
        } else {
            dropIndex = tiles.count
        }
        return .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { follow(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { follow(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropIndex = nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropIndex = nil }
        guard let item = dragged(sender) else { return false }
        delegate?.sidebarFavorite(item, at: dropIndex)
        return true
    }

    // MARK: a tile's requests

    fileprivate func open(_ item: SidebarItem) { delegate?.sidebarSelect(item, cause: "favorite") }

    /// A middle click puts an open favourite to sleep; it never takes one away.
    fileprivate func unload(_ item: SidebarItem) {
        if delegate?.sidebarIsLoaded(item) == true { delegate?.sidebarClose(item) }
    }

    fileprivate func toggleSound(_ item: SidebarItem) { delegate?.sidebarToggleSound(item) }

    fileprivate func tileMenu(for item: SidebarItem) -> NSMenu {
        let menu = NSMenu()
        if let home = item.pinnedURL, home != item.url {
            menu.addItem(ClosureMenuItem(L("tab.resetPin")) { [weak self] in self?.delegate?.sidebarResetPin(item) })
        }
        switch delegate?.sidebarSound(item) ?? .silent {
        case .playing: menu.addItem(ClosureMenuItem(L("tab.mute")) { [weak self] in self?.toggleSound(item) })
        case .muted: menu.addItem(ClosureMenuItem(L("tab.unmute")) { [weak self] in self?.toggleSound(item) })
        case .silent: break
        }
        menu.addItem(ClosureMenuItem(L("tab.copyLink")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.url, forType: .string)
        })
        menu.addItem(.separator())
        if delegate?.sidebarIsLoaded(item) == true {
            menu.addItem(ClosureMenuItem(L("tab.unload")) { [weak self] in self?.delegate?.sidebarClose(item) })
        }
        menu.addItem(ClosureMenuItem(L("favorites.unfavorite")) { [weak self] in self?.delegate?.sidebarUnfavorite(item) })
        menu.addItem(ClosureMenuItem(L("favorites.delete")) { [weak self] in self?.delegate?.sidebarRemove(item) })
        return menu
    }
}

/// One favourite: the site's icon on a soft tile, lit while it's in front, dimmer while its page is asleep, with a
/// speaker in its corner while it plays sound (a click on it quiets the tab).
private final class FavoriteTile: NSView {
    private static let fill = Theme.dynamic(dark: .white.withAlphaComponent(0.06), light: .white.withAlphaComponent(0.45))
    private static let fillHover = Theme.dynamic(dark: .white.withAlphaComponent(0.09), light: .white.withAlphaComponent(0.65))

    weak var grid: FavoritesGrid?
    var item: SidebarItem?
    var icon: NSImage? { didSet { image.image = icon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil) } }
    var loaded = false { didSet { image.alphaValue = loaded ? 1 : 0.55 } }
    var isActive = false { didSet { if isActive != oldValue { needsDisplay = true } } }
    /// Where a dragged tab would land: a line at the tile's left or right edge.
    var markedBefore = false { didSet { if markedBefore != oldValue { needsDisplay = true } } }
    var markedAfter = false { didSet { if markedAfter != oldValue { needsDisplay = true } } }
    let sound = SoundButton()

    private let image = NSImageView()
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var pressPoint: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layer?.cornerRadius = 4
        image.layer?.masksToBounds = true
        addSubview(image)
        sound.onClick = { [weak self] in
            guard let self, let item else { return }
            grid?.toggleSound(item)
        }
        addSubview(sound)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        image.frame = NSRect(x: (bounds.width - 20) / 2, y: (bounds.height - 20) / 2, width: 20, height: 20)
        sound.frame = NSRect(x: bounds.width - 22, y: 2, width: 20, height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        (isActive ? Theme.selectedCard : hovering ? Self.fillHover : Self.fill).setFill()
        shape.fill()
        Theme.hairline.setStroke()
        shape.stroke()
        guard markedBefore || markedAfter else { return }
        NSColor.controlAccentColor.setFill()
        let x = markedBefore ? 0 : bounds.width - 3
        NSBezierPath(roundedRect: NSRect(x: x, y: 6, width: 3, height: bounds.height - 12), xRadius: 1.5, yRadius: 1.5).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) { pressPoint = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressPoint, let item, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4
        else { return }
        pressPoint = nil
        let writer = NSPasteboardItem()
        writer.setString(item.id.uuidString, forType: SidebarList.itemType)
        let dragItem = NSDraggingItem(pasteboardWriter: writer)
        dragItem.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressPoint = nil }
        guard pressPoint != nil, let item, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        grid?.open(item)
    }

    override func otherMouseDown(with event: NSEvent) {}

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, let item { grid?.unload(item) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { item.flatMap { grid?.tileMenu(for: $0) } }

    private func snapshot() -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

extension FavoriteTile: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
}

/// While a tab is dragged and there are no favourites yet: where to drop it to make it one.
private final class FavoritesPlaceholder: NSView {
    var highlighted = false { didSet { if highlighted != oldValue { needsDisplay = true } } }
    private let label = NSTextField(labelWithString: L("favorites.drop"))

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 8, y: (bounds.height - 16) / 2, width: max(0, bounds.width - 16), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        if highlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            shape.fill()
        }
        let dash: [CGFloat] = [5, 4]
        shape.setLineDash(dash, count: dash.count, phase: 0)
        shape.lineWidth = 1.5
        (highlighted ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
        shape.stroke()
    }
}
