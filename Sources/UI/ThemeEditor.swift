import AppKit

/// Arc-style theme editor for a space: any colour from a hue × saturation field, its brightness down to
/// pure black, a tint intensity up to fully opaque, and a light / dark / automatic window.
/// Every change applies live through `onChange`.
final class ThemeEditor: NSViewController {
    struct Theme: Equatable {
        var color: NSColor
        var strength: CGFloat
        var appearance: Space.Appearance
    }

    private var theme: Theme
    private let onChange: (Theme) -> Void
    private var popover: NSPopover?
    // Kept apart from the colour: at zero brightness hue and saturation can't be read back from it.
    private var hue: CGFloat = 0
    private var saturation: CGFloat = 0
    private var brightness: CGFloat = 1

    private let modes = NSStackView()
    private let pad = ColorPad()
    private let swatches = NSStackView()
    private let brightnessSlider = GradientSlider(range: 0...1)
    private let intensity = GradientSlider(range: 0.04...1)

    static let presets = ["#E8E2DA", "#F2A0C0", "#A57FB0", "#EE6670", "#F7915A", "#F5CB5C", "#57D69A", "#6BB8E0", "#6C6F99"]

    init(theme: Theme, onChange: @escaping (Theme) -> Void) {
        self.theme = theme
        self.onChange = onChange
        let c = theme.color.usingColorSpace(.sRGB) ?? theme.color
        hue = c.hueComponent
        saturation = c.saturationComponent
        brightness = c.brightnessComponent
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let width: CGFloat = 300
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 430))

        modes.orientation = .horizontal
        modes.spacing = 6
        for (mode, symbol, tip) in [(Space.Appearance.system, "circle.lefthalf.filled", L("theme.mode.auto")),
                                    (.light, "sun.max.fill", L("theme.mode.light")),
                                    (.dark, "moon.fill", L("theme.mode.dark"))] {
            let button = ModeButton(symbol: symbol, tip: tip)
            button.onClick = { [weak self] in self?.update { $0.appearance = mode } }
            button.identifier = NSUserInterfaceItemIdentifier(mode.rawValue)
            modes.addArrangedSubview(button)
        }

        pad.onPick = { [weak self] hue, saturation in
            guard let self else { return }
            self.hue = hue
            self.saturation = ColorPad.saturation(at: saturation)
            if brightness < 0.15 { brightness = ColorPad.brightness }
            update { $0.color = self.composed }
        }

        swatches.orientation = .horizontal
        swatches.spacing = 6
        swatches.distribution = .equalSpacing
        for hex in Self.presets {
            let swatch = Swatch(color: NSColor(hex: hex))
            swatch.onClick = { [weak self] in
                guard let self else { return }
                let c = NSColor(hex: hex).usingColorSpace(.sRGB)!
                hue = c.hueComponent
                saturation = c.saturationComponent
                brightness = c.brightnessComponent
                update { $0.color = self.composed }
            }
            swatches.addArrangedSubview(swatch)
        }

        brightnessSlider.onChange = { [weak self] value in
            guard let self else { return }
            brightness = value
            update { $0.color = self.composed }
        }
        intensity.onChange = { [weak self] value in self?.update { $0.strength = value } }

        func label(_ key: String) -> NSTextField {
            let label = NSTextField(labelWithString: L(key))
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            return label
        }
        let brightnessLabel = label("theme.brightness")
        let intensityLabel = label("theme.intensity")

        [pad, modes, swatches, brightnessLabel, brightnessSlider, intensityLabel, intensity].forEach(root.addSubview)

        pad.frame = NSRect(x: 14, y: 198, width: width - 28, height: 218)
        let modesSize = modes.fittingSize
        modes.frame = NSRect(x: (width - modesSize.width) / 2, y: 198 + 218 - modesSize.height - 10, width: modesSize.width, height: modesSize.height)
        swatches.frame = NSRect(x: 18, y: 156, width: width - 36, height: 26)
        brightnessLabel.frame = NSRect(x: 18, y: 120, width: width - 36, height: 15)
        brightnessSlider.frame = NSRect(x: 14, y: 84, width: width - 28, height: 32)
        intensityLabel.frame = NSRect(x: 18, y: 58, width: width - 36, height: 15)
        intensity.frame = NSRect(x: 14, y: 22, width: width - 28, height: 32)
        view = root
        preferredContentSize = root.frame.size
        sync()
    }

    private func update(_ change: (inout Theme) -> Void) {
        var next = theme
        change(&next)
        guard next != theme else { return }
        theme = next
        sync()
        onChange(theme)
    }

    private var composed: NSColor {
        NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
    }

    private func sync() {
        pad.place(hue: hue, saturation: saturation, color: theme.color)
        brightnessSlider.value = brightness
        brightnessSlider.colors = (.black, NSColor(hue: hue, saturation: saturation, brightness: 1, alpha: 1))
        intensity.value = theme.strength
        intensity.colors = (theme.color.withAlphaComponent(0.08), theme.color)
        for case let button as ModeButton in modes.arrangedSubviews {
            button.selected = button.identifier?.rawValue == theme.appearance.rawValue
        }
    }

    func present(relativeTo rect: NSRect, of view: NSView, edge: NSRectEdge) {
        let popover = NSPopover()
        popover.contentViewController = self
        popover.behavior = .transient
        self.popover = popover
        popover.show(relativeTo: rect, of: view, preferredEdge: edge)
    }
}

/// Hue runs left to right, saturation from pale at the bottom to vivid at the top.
private final class ColorPad: NSView {
    var onPick: ((CGFloat, CGFloat) -> Void)?
    private var knob = NSPoint(x: 0.5, y: 0.5)
    private var knobColor = NSColor.white
    private var cached: (size: NSSize, image: CGImage)?

    static let brightness: CGFloat = 0.9

    static func color(hue: CGFloat, saturation: CGFloat) -> NSColor {
        NSColor(hue: hue, saturation: Self.saturation(at: saturation), brightness: brightness, alpha: 1)
    }

    /// The pad's vertical position as a saturation.
    static func saturation(at position: CGFloat) -> CGFloat { 0.08 + position * 0.82 }

    func place(hue: CGFloat, saturation: CGFloat, color: NSColor) {
        knob = NSPoint(x: hue, y: max(0, min(1, (saturation - 0.08) / 0.82)))
        knobColor = color
        needsDisplay = true
    }

    private var field: NSRect { bounds.insetBy(dx: 0, dy: 0) }

    private func gradient(_ size: NSSize) -> CGImage? {
        if let cached, cached.size == size { return cached.image }
        let scale = window?.backingScaleFactor ?? 2
        let w = max(1, Int(size.width * scale / 2)), h = max(1, Int(size.height * scale / 2))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for y in 0..<h {
            for x in 0..<w {
                let c = Self.color(hue: CGFloat(x) / CGFloat(max(w - 1, 1)), saturation: CGFloat(y) / CGFloat(max(h - 1, 1)))
                context.setFillColor(c.cgColor)
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        guard let image = context.makeImage() else { return nil }
        cached = (size, image)
        return image
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: field, xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let image = gradient(field.size), let context = NSGraphicsContext.current?.cgContext {
            context.interpolationQuality = .high
            context.draw(image, in: field)
        }
        NSGraphicsContext.restoreGraphicsState()

        // Kept inside the field, so even black (no hue, no saturation) sits within the corner, not over it.
        let center = NSPoint(x: max(field.minX + 14, min(field.maxX - 14, field.minX + knob.x * field.width)),
                             y: max(field.minY + 14, min(field.maxY - 14, field.minY + knob.y * field.height)))
        let ring = NSRect(x: center.x - 14, y: center.y - 14, width: 28, height: 28)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: ring).fill()
        NSGraphicsContext.restoreGraphicsState()
        knobColor.setFill()
        NSBezierPath(ovalIn: ring.insetBy(dx: 4, dy: 4)).fill()
    }

    private func pick(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hue = max(0, min(1, (point.x - field.minX) / field.width))
        let saturation = max(0, min(1, (point.y - field.minY) / field.height))
        onPick?(hue, saturation)
    }

    override func mouseDown(with event: NSEvent) { pick(event) }
    override func mouseDragged(with event: NSEvent) { pick(event) }
}

/// A track filled with a gradient and a round knob; brightness runs black → colour, intensity faint → full.
private final class GradientSlider: NSView {
    var onChange: ((CGFloat) -> Void)?
    var colors: (NSColor, NSColor) = (.black, .white) { didSet { needsDisplay = true } }
    var value: CGFloat = 0.5 { didSet { needsDisplay = true } }
    private let range: ClosedRange<CGFloat>

    init(range: ClosedRange<CGFloat>) {
        self.range = range
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var track: NSRect { NSRect(x: 12, y: bounds.midY - 5, width: bounds.width - 24, height: 10) }

    private var fraction: CGFloat {
        max(0, min(1, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: track, xRadius: 5, yRadius: 5)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(starting: colors.0, ending: colors.1)?.draw(in: track, angle: 0)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.1).setStroke()
        path.lineWidth = 1
        path.stroke()
        let x = track.minX + fraction * track.width
        let knob = NSRect(x: x - 10, y: bounds.midY - 10, width: 20, height: 20)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func pick(_ event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let f = max(0, min(1, (x - track.minX) / track.width))
        value = range.lowerBound + f * (range.upperBound - range.lowerBound)
        onChange?(value)
    }

    override func mouseDown(with event: NSEvent) { pick(event) }
    override func mouseDragged(with event: NSEvent) { pick(event) }
}

private final class Swatch: NSView {
    var onClick: (() -> Void)?
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        circle.fill()
        NSColor.black.withAlphaComponent(0.12).setStroke()
        circle.lineWidth = 1
        circle.stroke()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

private final class ModeButton: NSView {
    var onClick: (() -> Void)?
    var selected = false { didSet { needsDisplay = true; icon.contentTintColor = selected ? .labelColor : .secondaryLabelColor } }
    private let icon = NSImageView()

    init(symbol: String, tip: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 26))
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        icon.contentTintColor = .secondaryLabelColor
        addSubview(icon)
        toolTip = tip
        widthAnchor.constraint(equalToConstant: 30).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        icon.frame = bounds.insetBy(dx: 6, dy: 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard selected else { return }
        Theme.selectedCard.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

extension NSColor {
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
}
