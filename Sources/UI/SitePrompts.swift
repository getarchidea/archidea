import AppKit

/// What sites and the engine ask of the user — permissions, saving a password, adding an extension — as cards
/// in the corner of the page instead of system alerts: they carry the site's own icon, don't block the window,
/// and wait for their tab. A card shows while its tab is the one on screen; the others queue behind it.
final class SitePrompts {
    struct Request {
        let id: String
        /// The tab the request belongs to; nil for the window's own (an extension install).
        weak var tab: ArdiaCoreTab?
        let belongsToTab: Bool
        let icon: NSImage?
        let host: String
        let title: String
        var detail: String?
        var fields: [PromptCard.Field] = []
        /// Puts the caret in the first field (a name asked by the app); a site's card never takes the keyboard.
        var focusesField = false
        let buttons: [PromptCard.Button]
        /// Runs when the card goes away without a choice (closed, its tab closed, the engine took it back).
        let dismissed: () -> Void
    }

    private weak var host: NSView?
    private let activeTab: () -> ArdiaCoreTab?
    private var queue: [Request] = []
    private var shown: (id: String, card: PromptCard)?

    init(host: NSView, activeTab: @escaping () -> ArdiaCoreTab?) {
        self.host = host
        self.activeTab = activeTab
    }

    func add(_ request: Request) {
        queue.removeAll { $0.id == request.id }
        queue.append(request)
        refresh()
    }

    /// The engine (or a closed tab) took the request back.
    func remove(id: String) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue.remove(at: index)
        refresh()
    }

    /// Shows the first request that belongs on screen now; call when the visible tab changes.
    func refresh() {
        queue.removeAll { request in
            guard request.belongsToTab, request.tab == nil else { return false }
            request.dismissed()
            return true
        }
        let current = activeTab()
        let next = queue.first { !$0.belongsToTab || $0.tab === current }
        if shown?.id == next?.id { return }
        if let shown {
            let card = shown.card
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                card.animator().alphaValue = 0
            }, completionHandler: { card.removeFromSuperview() })
            self.shown = nil
        }
        guard let next, let host else { return }
        let card = PromptCard(request: next) { [weak self] in self?.finish(id: next.id) }
        card.frame.size = card.fittingSize
        card.alphaValue = 0
        host.addSubview(card)
        card.place()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            card.animator().alphaValue = 1
        }
        shown = (next.id, card)
    }

    /// A button or the close mark settled the request.
    private func finish(id: String) {
        queue.removeAll { $0.id == id }
        refresh()
    }
}

final class PromptCard: NSView {
    struct Field {
        let placeholder: String
        let value: String
        let secure: Bool
    }

    struct Button {
        enum Style { case primary, secondary, plain }
        let title: String
        let style: Style
        /// Gets the fields' current values.
        let action: ([String]) -> Void
    }

    private let request: SitePrompts.Request
    private let done: () -> Void
    private var inputs: [NSTextField] = []
    private let material = NSVisualEffectView()

    init(request: SitePrompts.Request, done: @escaping () -> Void) {
        self.request = request
        self.done = done
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        material.material = .popover
        material.blendingMode = .withinWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 14
        material.layer?.cornerCurve = .continuous
        material.layer?.masksToBounds = true
        material.layer?.borderWidth = 1
        material.translatesAutoresizingMaskIntoConstraints = false
        addSubview(material)

        let icon = NSImageView(image: request.icon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)!)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let host = NSTextField(labelWithString: request.host)
        host.font = .systemFont(ofSize: 12, weight: .medium)
        host.textColor = .secondaryLabelColor
        host.lineBreakMode = .byTruncatingMiddle
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: L("common.cancel"))!
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))!, target: self, action: #selector(closeTapped))
        close.isBordered = false
        close.contentTintColor = .tertiaryLabelColor
        let header = NSStackView(views: [icon, host, NSView(), close])
        header.spacing = 8
        header.distribution = .fill
        host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let title = NSTextField(wrappingLabelWithString: request.title)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .labelColor
        title.preferredMaxLayoutWidth = 300

        var views: [NSView] = [header, title]
        if let detail = request.detail, !detail.isEmpty {
            let label = NSTextField(wrappingLabelWithString: detail)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = 300
            views.append(label)
        }
        for field in request.fields {
            let input = field.secure ? NSSecureTextField(string: field.value) : NSTextField(string: field.value)
            input.placeholderString = field.placeholder
            input.font = .systemFont(ofSize: 13)
            input.bezelStyle = .roundedBezel
            input.controlSize = .regular
            input.widthAnchor.constraint(equalToConstant: 300).isActive = true
            input.target = self
            input.action = #selector(submit)
            inputs.append(input)
            views.append(input)
        }
        let buttons = NSStackView(views: [NSView()] + request.buttons.map { button in
            PromptButton(title: button.title, style: button.style) { [weak self] in
                guard let self else { return }
                button.action(inputs.map(\.stringValue))
                done()
            }
        })
        buttons.spacing = 8
        buttons.widthAnchor.constraint(equalToConstant: 300).isActive = true
        views.append(buttons)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(10, after: header)
        stack.setCustomSpacing(14, after: views[views.count - 2])
        header.widthAnchor.constraint(equalToConstant: 300).isActive = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(stack)
        NSLayoutConstraint.activate([
            material.leadingAnchor.constraint(equalTo: leadingAnchor),
            material.trailingAnchor.constraint(equalTo: trailingAnchor),
            material.topAnchor.constraint(equalTo: topAnchor),
            material.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: material.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        material.layer?.borderColor = Theme.hairline.cgColor
    }

    /// In the page's top left corner, clear of the sidebar when it's slid out over the page.
    func place() {
        guard let host = superview else { return }
        let clearance = (host as? ContentView)?.sidebarClearance ?? 0
        frame.origin = NSPoint(x: 12 + clearance, y: host.bounds.height - frame.height - 12)
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 14, cornerHeight: 14, transform: nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if request.focusesField, let first = inputs.first { window?.makeFirstResponder(first) }
    }

    /// Return in a field presses the card's main button.
    @objc private func submit() {
        guard let main = request.buttons.last(where: { $0.style == .primary }) else { return }
        main.action(inputs.map(\.stringValue))
        done()
    }

    @objc private func closeTapped() {
        request.dismissed()
        done()
    }
}

private final class PromptButton: NSView {
    private let title: String
    private let style: PromptCard.Button.Style
    private let action: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }
    private let font = NSFont.systemFont(ofSize: 12, weight: .semibold)

    init(title: String, style: PromptCard.Button.Style, action: @escaping () -> Void) {
        self.title = title
        self.style = style
        self.action = action
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil((title as NSString).size(withAttributes: [.font: font]).width) + (style == .plain ? 16 : 24), height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        let text: NSColor
        switch style {
        case .primary:
            NSColor.controlAccentColor.blended(withFraction: pressed ? 0.2 : hovering ? 0.08 : 0, of: .black)?.setFill()
            shape.fill()
            text = .white
        case .secondary:
            (pressed ? Theme.addressHover : hovering ? Theme.addressHover.withAlphaComponent(0.8) : Theme.keycap).setFill()
            shape.fill()
            text = .labelColor
        case .plain:
            if hovering || pressed {
                Theme.hover.setFill()
                shape.fill()
            }
            text = .secondaryLabelColor
        }
        let string = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: text])
        let size = string.size()
        string.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = isUnderPointer }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
}
