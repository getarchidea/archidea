import AppKit

/// A row of the app icon's looks; a click switches the Dock icon right away.
final class IconChoiceView: NSStackView {
    private let tileSize: CGFloat
    private let ring: NSColor
    private let showsNames: Bool
    var onChange: ((String) -> Void)?

    init(tileSize: CGFloat = 40, ring: NSColor = .controlAccentColor, showsNames: Bool = false) {
        self.tileSize = tileSize
        self.ring = ring
        self.showsNames = showsNames
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = showsNames ? 10 : tileSize * 0.2
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Rows of five: the dark tiles, then the light ones.
    private func rebuild() {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        var row: NSStackView?
        for (index, id) in IconChoice.ids.enumerated() {
            if index % 5 == 0 {
                let next = NSStackView()
                next.spacing = showsNames ? 4 : tileSize * 0.2
                addArrangedSubview(next)
                row = next
            }
            let selected = id == IconChoice.current
            let tile = IconTile(id: id, size: tileSize, ring: ring, selected: selected) { [weak self] in
                IconChoice.choose(id)
                self?.rebuild()
                self?.onChange?(id)
            }
            guard showsNames else {
                row?.addArrangedSubview(tile)
                continue
            }
            let name = NSTextField(labelWithString: L("icon.\(id.split(separator: "-").last ?? "")"))
            name.font = .systemFont(ofSize: 11, weight: selected ? .semibold : .regular)
            name.textColor = selected ? .labelColor : .secondaryLabelColor
            name.alignment = .center
            name.lineBreakMode = .byTruncatingTail
            let column = NSStackView(views: [tile, name])
            column.orientation = .vertical
            column.spacing = 6
            // Equal columns, so long names don't push the tiles apart unevenly.
            column.widthAnchor.constraint(equalToConstant: tileSize + 26).isActive = true
            name.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            row?.addArrangedSubview(column)
        }
    }
}

private final class IconTile: NSView {
    private let image: NSImage?
    private let ring: NSColor
    private let selected: Bool
    private let action: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }

    init(id: String, size: CGFloat, ring: NSColor, selected: Bool, action: @escaping () -> Void) {
        image = IconChoice.preview(id)
        self.ring = ring
        self.selected = selected
        self.action = action
        super.init(frame: .zero)
        toolTip = L("icon.\(id.split(separator: "-").last ?? "")")
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        // The previews carry Apple's grid margin (100 of 1024 on each side); the ring hugs the tile itself.
        let inset = bounds.width * 100 / 1024
        let tile = bounds.insetBy(dx: inset, dy: inset)
        image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: hovering || selected ? 1 : 0.85)
        guard selected else { return }
        ring.setStroke()
        let outline = NSBezierPath(roundedRect: tile.insetBy(dx: -2.5, dy: -2.5), xRadius: tile.width * 0.25, yRadius: tile.width * 0.25)
        outline.lineWidth = 2
        outline.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = isUnderPointer }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { action() }
}
