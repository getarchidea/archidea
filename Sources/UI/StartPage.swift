import AppKit

/// What the window shows with no tab open: a way to search or go somewhere, the sites visited most, and the tabs
/// closed lately. Quiet on purpose — the page's own colour, no pictures, nothing that changes by itself.
final class StartPage: NSView {
    struct Closed {
        let url: String
        let title: String
    }

    var onSearch: (() -> Void)?
    var onOpen: ((String) -> Void)?
    var onHide: ((String) -> Void)?
    var onReopen: ((Int) -> Void)?

    private let search = StartSearch()
    private var tiles: [SiteTile] = []
    private let closedTitle = NSTextField(labelWithString: L("start.closed"))
    private var closedRows: [ClosedRow] = []
    private let hints = NSTextField(labelWithString: "")

    private static let column: CGFloat = 680
    private static let tileSize = NSSize(width: 76, height: 92)

    /// Where the search field is, for the address bar to open right over it.
    var searchField: NSView { search }

    override init(frame: NSRect) {
        super.init(frame: frame)
        search.onClick = { [weak self] in self?.onSearch?() }
        addSubview(search)
        closedTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        closedTitle.textColor = .tertiaryLabelColor
        addSubview(closedTitle)
        hints.font = .systemFont(ofSize: 11.5)
        hints.textColor = .tertiaryLabelColor
        hints.alignment = .center
        hints.stringValue = [("⌘T", L("empty.newTab")), ("⌘L", L("empty.openLocation")), ("⌘S", L("empty.toggleSidebar")),
                             ("⌥⌘→", L("empty.nextSpace"))].map { "\($0.0)  \($0.1)" }.joined(separator: "     ")
        addSubview(hints)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func show(sites: [HistoryIndex.Site], closed: [Closed]) {
        tiles.forEach { $0.removeFromSuperview() }
        tiles = sites.map { site in
            let tile = SiteTile(site: site)
            tile.onClick = { [weak self] in self?.onOpen?(site.url) }
            tile.onHide = { [weak self] in self?.onHide?(site.host) }
            addSubview(tile)
            return tile
        }
        closedRows.forEach { $0.removeFromSuperview() }
        closedRows = closed.enumerated().map { index, entry in
            let row = ClosedRow(entry: entry)
            row.onClick = { [weak self] in self?.onReopen?(index) }
            addSubview(row)
            return row
        }
        closedTitle.isHidden = closed.isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = min(Self.column, bounds.width - 64)
        let left = (bounds.width - width) / 2
        // Everything sits a little above the middle, more so when there's less of it.
        var height: CGFloat = 52
        let perRow = max(1, min(8, Int((width + 8) / (Self.tileSize.width + 8))))
        let rows = (tiles.count + perRow - 1) / perRow
        if rows > 0 { height += 36 + CGFloat(rows) * Self.tileSize.height }
        if !closedRows.isEmpty { height += 40 + 22 + CGFloat(closedRows.count) * 34 }
        var y = max(48, (bounds.height - height) * 0.38)

        search.frame = NSRect(x: left, y: y, width: width, height: 52)
        y += 52 + 36

        if rows > 0 {
            for row in 0..<rows {
                let inRow = min(perRow, tiles.count - row * perRow)
                let rowWidth = CGFloat(inRow) * Self.tileSize.width + CGFloat(inRow - 1) * 8
                var x = (bounds.width - rowWidth) / 2
                for tile in tiles[(row * perRow)..<(row * perRow + inRow)] {
                    tile.frame = NSRect(origin: NSPoint(x: x, y: y), size: Self.tileSize)
                    x += Self.tileSize.width + 8
                }
                y += Self.tileSize.height
            }
        }

        if !closedRows.isEmpty {
            y += 40
            closedTitle.frame = NSRect(x: left + 10, y: y, width: width - 20, height: 16)
            y += 22
            for row in closedRows {
                row.frame = NSRect(x: left, y: y, width: width, height: 32)
                y += 34
            }
        }
        hints.frame = NSRect(x: 0, y: bounds.height - 36, width: bounds.width, height: 16)
        hints.isHidden = y > bounds.height - 48
    }
}

/// Looks like an address field and opens the real one (the command bar), with what was typed into it.
private final class StartSearch: NSView {
    var onClick: (() -> Void)?
    private let glyph = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!
        .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))!)
    private let placeholder = NSTextField(labelWithString: L("command.placeholder"))
    private let cap = KeyCap("⌘ T")
    private var hovering = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        glyph.contentTintColor = .tertiaryLabelColor
        placeholder.font = .systemFont(ofSize: 17)
        placeholder.textColor = .tertiaryLabelColor
        [glyph, placeholder, cap].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        glyph.frame = NSRect(x: 18, y: (bounds.height - 18) / 2, width: 18, height: 18)
        placeholder.frame = NSRect(x: 46, y: (bounds.height - 22) / 2, width: bounds.width - 130, height: 22)
        cap.frame = NSRect(x: bounds.width - 16 - 44, y: (bounds.height - 22) / 2, width: 44, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        (hovering ? Theme.addressHover : Theme.startField).setFill()
        shape.fill()
        Theme.hairline.setStroke()
        shape.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = isUnderPointer }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func cursorUpdate(with event: NSEvent) { NSCursor.iBeam.set() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// A site: its icon on a soft square (its initial until the icon is known), its name under it.
private final class SiteTile: NSView {
    var onClick: (() -> Void)?
    var onHide: (() -> Void)?
    private let site: HistoryIndex.Site
    private let icon = NSImageView()
    private let initial = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private var hovering = false { didSet { needsDisplay = true } }

    init(site: HistoryIndex.Site) {
        self.site = site
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        initial.font = .systemFont(ofSize: 22, weight: .semibold)
        initial.textColor = .secondaryLabelColor
        initial.alignment = .center
        initial.stringValue = String(Self.label(for: site).prefix(1)).uppercased()
        name.font = .systemFont(ofSize: 11.5)
        name.textColor = .secondaryLabelColor
        name.alignment = .center
        name.lineBreakMode = .byTruncatingTail
        name.stringValue = Self.label(for: site)
        toolTip = site.host
        [icon, initial, name].forEach(addSubview)
        if let image = Favicons.shared.cached(site.url) { setIcon(image) } else {
            Favicons.shared.lookUp(site.url) { [weak self] image in self?.setIcon(image) }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// The site's name when its front page is titled with just that ("GitHub", "YouTube"), else its host without
    /// the www: a title with words and separators ("Recents – Google", "404: Not Found") says more about a page
    /// than the site.
    static func label(for site: HistoryIndex.Site) -> String {
        let host = site.host.hasPrefix("www.") ? String(site.host.dropFirst(4)) : site.host
        let title = site.title.trimmingCharacters(in: .whitespaces)
        let plain = title.rangeOfCharacter(from: CharacterSet(charactersIn: " –—-|:·•/\\")) == nil
        return !title.isEmpty && title.count <= 14 && plain ? title : host
    }

    private func setIcon(_ image: NSImage) {
        icon.image = image
        initial.isHidden = true
        tone = Self.tone(of: image)
        needsDisplay = true
    }

    /// How light the icon's visible pixels are, 0…1 (nil until known): a white icon on a light page, or a black one
    /// on a dark page, gets a plate of the other kind so it doesn't vanish.
    private var tone: CGFloat?

    private static func tone(of image: NSImage) -> CGFloat? {
        let side = 16
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        var sum: CGFloat = 0, weight: CGFloat = 0
        for x in 0..<side {
            for y in 0..<side {
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.3 else { continue }
                sum += (0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent) * color.alphaComponent
                weight += color.alphaComponent
            }
        }
        return weight > 8 ? sum / weight : nil
    }

    private var plate: NSRect { NSRect(x: (bounds.width - 56) / 2, y: 4, width: 56, height: 56) }

    override func layout() {
        super.layout()
        icon.frame = plate.insetBy(dx: 14, dy: 14)
        initial.frame = NSRect(x: plate.minX, y: plate.midY - 14, width: plate.width, height: 28)
        name.frame = NSRect(x: 0, y: plate.maxY + 8, width: bounds.width, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fill: NSColor
        if let tone, !dark, tone > 0.85 {
            fill = NSColor(white: hovering ? 0.22 : 0.16, alpha: 1)
        } else if let tone, dark, tone < 0.12 {
            fill = NSColor(white: hovering ? 0.92 : 0.86, alpha: 1)
        } else {
            fill = hovering ? Theme.addressHover : Theme.keycap
        }
        fill.setFill()
        NSBezierPath(roundedRect: plate, xRadius: 14, yRadius: 14).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = isUnderPointer }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(L("start.hide")) { [weak self] in self?.onHide?() })
        return menu
    }
}

/// A tab closed lately, to have back.
private final class ClosedRow: NSView {
    var onClick: (() -> Void)?
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let host = NSTextField(labelWithString: "")
    private var hovering = false { didSet { needsDisplay = true } }

    init(entry: StartPage.Closed) {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.image = Favicons.shared.cached(entry.url) ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        icon.contentTintColor = .tertiaryLabelColor
        Favicons.shared.lookUp(entry.url) { [weak self] image in
            self?.icon.image = image
            self?.icon.contentTintColor = nil
        }
        let site = URL(string: entry.url)?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? entry.url
        title.stringValue = entry.title.isEmpty ? site : entry.title
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        host.stringValue = site
        host.font = .systemFont(ofSize: 12)
        host.textColor = .tertiaryLabelColor
        host.alignment = .right
        host.lineBreakMode = .byTruncatingMiddle
        [icon, title, host].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 10, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let hostWidth = min(220, ceil(host.attributedStringValue.size().width) + 4)
        host.frame = NSRect(x: bounds.width - 10 - hostWidth, y: (bounds.height - 16) / 2, width: hostWidth, height: 16)
        title.frame = NSRect(x: 36, y: (bounds.height - 17) / 2, width: host.frame.minX - 48, height: 17)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        Theme.hover.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = isUnderPointer }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}
