import AppKit
import ArchideaCore

/// What the window shows with no tab open: the space it's in, a field to search or go somewhere and the few keys worth
/// knowing, on a soft wash of the space's colour. Nothing else: sites visited and tabs closed are in History and on
/// ⇧⌘T, favourites are pinned in the sidebar.
final class StartPage: NSView {
    var onSearch: (() -> Void)?

    private let backdrop = StartBackdrop()
    private let badge = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let search = StartSearch()
    private let hints = [("⌘T", L("start.hint.newTab")), ("⇧⌘T", L("start.hint.reopen")), ("⌥⌘\\", L("start.hint.split")),
                         ("⌘S", L("start.hint.sidebar"))].map { StartHint(keys: $0.0, text: $0.1) }

    private static let column: CGFloat = 560

    /// Where the search field is, for the address bar to open right over it.
    var searchField: NSView { search }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(backdrop)
        badge.imageScaling = .scaleProportionallyUpOrDown
        name.font = .systemFont(ofSize: 14, weight: .medium)
        name.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingTail
        search.onClick = { [weak self] in self?.onSearch?() }
        for view in [badge, name, search] as [NSView] { addSubview(view) }
        hints.forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// The space the window shows: its colour, icon and name. A private window has a quiet look of its own.
    func show(_ space: Space, isPrivate: Bool) {
        backdrop.color = isPrivate ? NSColor(srgbRed: 0.42, green: 0.42, blue: 0.5, alpha: 1) : NSColor(hex: space.colorHex)
        badge.image = isPrivate ? NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium)) : Glyphs.image(space.symbol, filled: true, pointSize: 15)
        badge.contentTintColor = .secondaryLabelColor
        name.stringValue = isPrivate ? L("start.private") : space.name
        needsLayout = true
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        let width = min(Self.column, bounds.width - 64)

        // The hints flow in rows as wide as the field, each row centred.
        var rows: [[StartHint]] = [[]]
        var rowWidth: CGFloat = 0
        for hint in hints {
            let next = rowWidth + (rows[rows.count - 1].isEmpty ? 0 : StartHint.spacing) + hint.width
            if next > width, !rows[rows.count - 1].isEmpty {
                rows.append([hint])
                rowWidth = hint.width
            } else {
                rows[rows.count - 1].append(hint)
                rowWidth = next
            }
        }
        let hintsHeight = CGFloat(rows.count) * StartHint.height + CGFloat(rows.count - 1) * 10

        // The space, the field and the keys sit together a little above the middle.
        let height = 22 + 18 + 52 + 28 + hintsHeight
        var y = max(40, (bounds.height - height) * 0.4)

        let nameWidth = min(width - 26, ceil(name.attributedStringValue.size().width) + 4)
        let left = (bounds.width - 18 - 8 - nameWidth) / 2
        badge.frame = NSRect(x: left, y: y + 2, width: 18, height: 18)
        name.frame = NSRect(x: left + 26, y: y + 2, width: nameWidth, height: 18)
        y += 22 + 18

        search.frame = NSRect(x: (bounds.width - width) / 2, y: y, width: width, height: 52)
        y += 52 + 28

        for row in rows {
            let total = row.map(\.width).reduce(0, +) + CGFloat(max(0, row.count - 1)) * StartHint.spacing
            var x = (bounds.width - total) / 2
            for hint in row {
                hint.frame = NSRect(x: x, y: y, width: hint.width, height: StartHint.height)
                x += hint.width + StartHint.spacing
            }
            y += StartHint.height + 10
        }
    }
}

/// The page's wash: a wide glow of the space's colour from the top left and a fainter one of a neighbouring hue from
/// the bottom right, with a fine grain over them so the gradient doesn't fall into bands.
private final class StartBackdrop: NSView {
    var color = NSColor.systemBlue {
        didSet { needsDisplay = true }
    }

    private static let grain: NSImage = {
        let side = 128
        let image = NSImage(size: NSSize(width: side, height: side))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: side * 4, bitsPerPixel: 32),
              let data = rep.bitmapData else { return image }
        for pixel in 0..<(side * side) {
            // Premultiplied: a white speck's colour is its alpha, a dark one's is nothing.
            let alpha = UInt8.random(in: 0...10)
            let value = Bool.random() ? alpha : 0
            data[pixel * 4] = value
            data[pixel * 4 + 1] = value
            data[pixel * 4 + 2] = value
            data[pixel * 4 + 3] = alpha
        }
        image.addRepresentation(rep)
        return image
    }()

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let base = color.usingColorSpace(.sRGB) ?? color
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let neighbour = NSColor(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: saturation,
                                brightness: brightness, alpha: 1)
        let reach = max(bounds.width, bounds.height)
        // The view isn't flipped: the top is maxY.
        glow(base, strength: dark ? 0.32 : 0.28, at: NSPoint(x: bounds.minX + bounds.width * 0.18, y: bounds.maxY + reach * 0.08),
             radius: reach * 0.95)
        glow(neighbour, strength: dark ? 0.18 : 0.16, at: NSPoint(x: bounds.maxX, y: bounds.minY), radius: reach * 0.7)
        NSColor(patternImage: Self.grain).setFill()
        bounds.fill(using: .sourceOver)
    }

    private func glow(_ color: NSColor, strength: CGFloat, at center: NSPoint, radius: CGFloat) {
        let colors = [color.withAlphaComponent(strength), color.withAlphaComponent(strength * 0.4), color.withAlphaComponent(0)]
        NSGradient(colors: colors, atLocations: [0, 0.45, 1], colorSpace: .sRGB)?
            .draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
    }
}

/// Looks like an address field and opens the real one (the command bar), with what was typed into it.
private final class StartSearch: NSView {
    private static let fill = Theme.dynamic(dark: .white.withAlphaComponent(0.07), light: .white.withAlphaComponent(0.72))
    private static let fillHover = Theme.dynamic(dark: .white.withAlphaComponent(0.11), light: .white.withAlphaComponent(0.88))

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
        (hovering ? Self.fillHover : Self.fill).setFill()
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

/// A key worth knowing: its keycap and what it does, quietly.
private final class StartHint: NSView {
    static let height: CGFloat = 22
    static let spacing: CGFloat = 22
    /// KeyCap's own.
    private static let capFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let textFont = NSFont.systemFont(ofSize: 12)

    private let cap: KeyCap
    private let label = NSTextField(labelWithString: "")
    private let capWidth: CGFloat
    let width: CGFloat

    init(keys: String, text: String) {
        cap = KeyCap(keys)
        capWidth = ceil((keys as NSString).size(withAttributes: [.font: Self.capFont]).width) + 14
        width = capWidth + 7 + ceil((text as NSString).size(withAttributes: [.font: Self.textFont]).width) + 2
        super.init(frame: .zero)
        label.stringValue = text
        label.font = Self.textFont
        label.textColor = .tertiaryLabelColor
        addSubview(cap)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        cap.frame = NSRect(x: 0, y: 0, width: capWidth, height: Self.height)
        let textHeight = ceil(label.cell?.cellSize.height ?? 16)
        label.frame = NSRect(x: capWidth + 7, y: (Self.height - textHeight) / 2, width: bounds.width - capWidth - 7, height: textHeight)
    }
}
