import AppKit
import ArchideaCore

// MARK: - Progress

final class ProgressBar: NSView {
    private let fill = CAGradientLayer()
    private var fraction: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fill.colors = [NSColor(srgbRed: 0.65, green: 0.17, blue: 1, alpha: 1).cgColor,
                       NSColor(srgbRed: 1, green: 0.36, blue: 0.71, alpha: 1).cgColor,
                       NSColor(srgbRed: 1, green: 0.36, blue: 0.71, alpha: 0).cgColor]
        fill.locations = [0, 0.85, 1]
        fill.startPoint = CGPoint(x: 0, y: 0.5)
        fill.endPoint = CGPoint(x: 1, y: 0.5)
        fill.cornerRadius = 3
        layer?.addSublayer(fill)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(fraction: CGFloat, animated: Bool) {
        self.fraction = fraction
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.6 : 0)
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1))
        fill.frame = NSRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        set(fraction: fraction, animated: false)
    }
}

// MARK: - Controls

final class OnboardingButton: NSView {
    enum Style { case light, dark, link }

    private let style: Style
    var title = "" { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var action: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var font: NSFont { style == .link ? .systemFont(ofSize: 12, weight: .medium) : .systemFont(ofSize: 13, weight: .semibold) }

    override var intrinsicContentSize: NSSize {
        let width = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        return style == .link ? NSSize(width: width, height: 20) : NSSize(width: width + 60, height: 42)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        var text = NSColor.white
        switch style {
        case .light:
            NSColor(white: pressed ? 0.7 : hovering ? 0.9 : 0.85, alpha: 1).setFill()
            shape.fill()
            text = NSColor(white: 0.08, alpha: 1)
        case .dark:
            NSColor(white: pressed ? 0.2 : hovering ? 0.16 : 0.12, alpha: 1).setFill()
            shape.fill()
            text = NSColor(white: 0.62, alpha: 1)
        case .link:
            text = .white.withAlphaComponent(hovering ? 0.8 : 0.42)
        }
        let string = NSMutableAttributedString(string: title, attributes: [.font: font, .foregroundColor: text])
        if style == .light {
            string.append(NSAttributedString(string: "  ↩", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: text.withAlphaComponent(0.45)]))
        }
        let size = string.size()
        string.draw(at: NSPoint(x: style == .link ? 0 : (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    func perform() {
        guard !isHidden, window != nil else { return }
        action?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = isUnderPointer }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { perform() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A rounded card with a hairline: an option with a radio or a checkbox, or an import part with its progress.
final class ChoiceCard: NSView {
    enum Mark { case radio, check, done, busy, none }

    let title: String
    private let mark: Mark
    private let toggles: Bool
    private let action: () -> Void
    private let spinner = NSProgressIndicator()
    var selected: Bool { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }

    init(icon: NSImage?, title: String, detail: String?, mark: Mark, selected: Bool, compact: Bool = false, toggles: Bool = false,
         action: @escaping () -> Void) {
        self.title = title
        self.mark = mark
        self.selected = selected
        self.toggles = toggles
        self.action = action
        super.init(frame: .zero)
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.textColor = .white.withAlphaComponent(0.92)
        name.lineBreakMode = .byTruncatingTail
        var texts: [NSView] = [name]
        if let detail, compact {
            let info = NSTextField(labelWithString: detail)
            info.font = .systemFont(ofSize: 12)
            info.textColor = .white.withAlphaComponent(0.5)
            info.lineBreakMode = .byTruncatingTail
            texts.append(info)
        } else if let detail {
            let info = NSTextField(wrappingLabelWithString: detail)
            info.font = .systemFont(ofSize: 12)
            info.textColor = .white.withAlphaComponent(0.45)
            info.preferredMaxLayoutWidth = 330
            texts.append(info)
        }
        let text = NSStackView(views: texts)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        var views: [NSView] = []
        if let icon {
            let image = NSImageView(image: icon)
            image.imageScaling = .scaleProportionallyUpOrDown
            if icon.isTemplate { image.contentTintColor = .white.withAlphaComponent(0.8) }
            image.widthAnchor.constraint(equalToConstant: compact ? 18 : 26).isActive = true
            image.heightAnchor.constraint(equalToConstant: compact ? 18 : 26).isActive = true
            views.append(image)
        }
        views.append(text)
        let row = NSStackView(views: views)
        row.spacing = 12
        row.alignment = .centerY
        let leading: CGFloat = mark == .check ? 46 : 16
        for view in [row, spinner] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = mark != .busy
        if mark == .busy { spinner.startAnimation(nil) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: compact ? 50 : 60),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -44),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 12),
            spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentHuggingPriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        NSColor(white: hovering ? 0.1 : 0.075, alpha: 1).setFill()
        shape.fill()
        NSColor.white.withAlphaComponent(selected && mark == .radio ? 0.5 : 0.14).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        switch mark {
        case .radio:
            let ring = NSRect(x: bounds.maxX - 36, y: bounds.midY - 10, width: 20, height: 20)
            if selected {
                NSColor.white.setFill()
                NSBezierPath(ovalIn: ring).fill()
                NSColor.black.setFill()
                NSBezierPath(ovalIn: ring.insetBy(dx: 3, dy: 3)).fill()
                NSColor.white.setFill()
                NSBezierPath(ovalIn: ring.insetBy(dx: 5.5, dy: 5.5)).fill()
            } else {
                NSColor.white.withAlphaComponent(0.35).setStroke()
                let path = NSBezierPath(ovalIn: ring.insetBy(dx: 0.75, dy: 0.75))
                path.lineWidth = 1.5
                path.stroke()
            }
        case .check:
            let box = NSRect(x: 16, y: bounds.midY - 10, width: 20, height: 20)
            let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
            if selected {
                NSColor.white.setFill()
                path.fill()
                drawTick(in: box, color: .black)
            } else {
                NSColor.white.withAlphaComponent(0.35).setStroke()
                path.lineWidth = 1.5
                path.stroke()
            }
        case .done:
            let disc = NSRect(x: bounds.maxX - 36, y: bounds.midY - 10, width: 20, height: 20)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: disc).fill()
            drawTick(in: disc, color: .black)
        case .busy, .none:
            break
        }
    }

    private func drawTick(in box: NSRect, color: NSColor) {
        let tick = NSBezierPath()
        tick.move(to: NSPoint(x: box.minX + 5.5, y: box.midY))
        tick.line(to: NSPoint(x: box.minX + 8.5, y: box.minY + 6))
        tick.line(to: NSPoint(x: box.maxX - 5, y: box.maxY - 6))
        tick.lineWidth = 2
        tick.lineCapStyle = .round
        tick.lineJoinStyle = .round
        color.setStroke()
        tick.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard mark == .radio || mark == .check else { return }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = isUnderPointer }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {
        guard mark == .radio || mark == .check else { return }
        if toggles { selected.toggle() }
        action()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
}

final class FeatureRow: NSStackView {
    init(symbol: String, text: String) {
        super.init(frame: .zero)
        let badge = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))!)
        badge.contentTintColor = .white.withAlphaComponent(0.75)
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 9
        badge.layer?.borderWidth = 1
        badge.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        badge.widthAnchor.constraint(equalToConstant: 32).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 14)
        label.textColor = .white.withAlphaComponent(0.72)
        label.preferredMaxLayoutWidth = 380
        setViews([badge, label], in: .leading)
        spacing = 14
        alignment = .centerY
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class OnboardingHairline: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 440, height: 1) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.12).setFill()
        bounds.fill()
    }
}

/// Keys drawn as keys: lit from above, a hairline edge and a darker lip at the bottom.
final class KeyCaps: NSView {
    private let keys: [String]
    private let font = NSFont.systemFont(ofSize: 12, weight: .medium)

    init(keys: [String]) {
        self.keys = keys
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func width(of key: String) -> CGFloat {
        max(22, ceil((key as NSString).size(withAttributes: [.font: font]).width) + 12)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: keys.map(width).reduce(0, +) + CGFloat(max(0, keys.count - 1)) * 4, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 0
        for key in keys {
            let rect = NSRect(x: x, y: 0, width: width(of: key), height: bounds.height)
            NSColor(white: 0.05, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            let face = NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY + 1.5, width: rect.width, height: rect.height - 1.5),
                                    xRadius: 5, yRadius: 5)
            NSGradient(colors: [NSColor(white: 0.24, alpha: 1), NSColor(white: 0.17, alpha: 1)])!.draw(in: face, angle: -90)
            NSColor.white.withAlphaComponent(0.1).setStroke()
            face.lineWidth = 1
            face.stroke()
            let text = NSAttributedString(string: key, attributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.85)])
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.minY + 1.5 + (rect.height - 1.5 - size.height) / 2))
            x = rect.maxX + 4
        }
    }
}

final class ShortcutRow: NSView {
    init(title: String, keys: [String]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.backgroundColor = NSColor(white: 0.075, alpha: 1).cgColor
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .white.withAlphaComponent(0.85)
        let caps = KeyCaps(keys: keys)
        for view in [label, caps] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 440),
            heightAnchor.constraint(equalToConstant: 42),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            caps.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            caps.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class OnboardingSwatch: NSView {
    private let color: NSColor
    private let selected: Bool
    private let action: () -> Void

    init(hex: String, selected: Bool, action: @escaping () -> Void) {
        color = NSColor(hex: hex)
        self.selected = selected
        self.action = action
        super.init(frame: .zero)
        toolTip = SpaceStyle.colorName(hex)
        widthAnchor.constraint(equalToConstant: 26).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if selected {
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 1.5
            ring.stroke()
        }
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 5, dy: 5)).fill()
    }

    override func mouseDown(with event: NSEvent) { action() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
