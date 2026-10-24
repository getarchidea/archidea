import AppKit
import ArchideaCore
import ArdiaCore

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

    /// Every waiting request answered "not now" (its page is moving to another window).
    func dismissAll() {
        let waiting = queue
        queue.removeAll()
        waiting.forEach { $0.dismissed() }
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
    /// A card is answered once, by whichever comes first: a button, Return, the close mark.
    private var settled = false
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
            // Only Return sends it. Clicking a button, or the card going away, ends the editing too, and sent the
            // card's main action a second time: a new space was created twice.
            input.cell?.sendsActionOnEndEditing = false
            inputs.append(input)
            views.append(input)
        }
        let buttons = NSStackView(views: [NSView()] + request.buttons.map { button in
            PromptButton(title: button.title, style: button.style) { [weak self] in
                guard let self else { return }
                settle { button.action(inputs.map(\.stringValue)) }
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
        settle { main.action(inputs.map(\.stringValue)) }
    }

    @objc private func closeTapped() {
        settle { request.dismissed() }
    }

    private func settle(_ answer: () -> Void) {
        guard !settled else { return }
        settled = true
        answer()
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

// MARK: - The engine's requests as cards

extension SitePrompts {
    /// Saving or updating a password the page just used.
    func addPasswordPrompt(_ prompt: [String: Any], tab: ArdiaCoreTab) {
        let state = prompt["state"] as? String ?? ""
        guard state == "save" || state == "update" else { return }
        let origin = prompt["origin"] as? String ?? ""
        let update = state == "update"
        let decline = update ? "nope" : "dismiss"
        var buttons: [PromptCard.Button] = []
        if !update {
            buttons.append(.init(title: L("password.never"), style: .plain) { [weak tab] _ in
                tab?.resolvePasswordPrompt("never", username: nil, password: nil)
            })
        }
        buttons.append(.init(title: L("password.notNow"), style: .secondary) { [weak tab] _ in
            tab?.resolvePasswordPrompt(decline, username: nil, password: nil)
        })
        buttons.append(.init(title: update ? L("password.update") : L("password.save"), style: .primary) { [weak tab] values in
            let username = values.first.flatMap { $0.isEmpty ? nil : $0 }
            tab?.resolvePasswordPrompt(update ? "update" : "save", username: username, password: nil)
        })
        add(.init(id: "password-\(tab.tabId)", tab: tab, belongsToTab: true, icon: tab.favicon,
                  host: URL(string: origin)?.host ?? origin,
                  title: update ? L("password.update.title") : L("password.save.title"),
                  fields: [.init(placeholder: L("password.username"), value: prompt["username"] as? String ?? "", secure: false)],
                  buttons: buttons,
                  dismissed: { [weak tab] in tab?.resolvePasswordPrompt(decline, username: nil, password: nil) }))
    }

    /// A site asking for the camera, location, notifications…
    func addPermissionRequest(_ request: [String: Any], tab: ArdiaCoreTab) {
        let id = request["id"] as? String ?? ""
        let origin = request["origin"] as? String ?? ""
        let kinds = (request["permissions"] as? [String] ?? []).map(Prompts.permissionName).joined(separator: ", ")
        let resolve = { (result: String, remember: Bool) in
            ArdiaCoreEngine.shared?.resolvePermission(id, result: result, remember: remember)
        }
        add(.init(id: id, tab: tab, belongsToTab: true, icon: tab.favicon, host: URL(string: origin)?.host ?? origin,
                  title: L("permission.wants", kinds), buttons: [
                      .init(title: L("permission.deny"), style: .plain) { _ in resolve("deny", true) },
                      .init(title: L("permission.once"), style: .secondary) { _ in resolve("accept", false) },
                      .init(title: L("permission.allow"), style: .primary) { _ in resolve("accept", true) },
                  ], dismissed: { resolve("dismiss", false) }))
    }

    /// A page wants to open another app (a `zoommtg:` or `slack:` link).
    func addExternalAppRequest(_ request: [String: Any], tab: ArdiaCoreTab) {
        let id = request["id"] as? String ?? ""
        let origin = request["origin"] as? String
        let host = origin.flatMap { URL(string: $0)?.host } ?? origin ?? tab.committedOrigin ?? ""
        let resolve = { (open: Bool, remember: Bool) in ArdiaCoreEngine.resolveExternalApp(id, open: open, remember: remember) }
        guard let app = request["app"] as? String else {
            // Nothing on this Mac opens the link's kind.
            let scheme = request["scheme"] as? String ?? ""
            add(.init(id: "app-\(id)", tab: tab, belongsToTab: true, icon: tab.favicon, host: host,
                      title: L("externalApp.none", scheme), buttons: [.init(title: "OK", style: .primary) { _ in resolve(false, false) }],
                      dismissed: { resolve(false, false) }))
            return
        }
        // The app's own icon: from its bundle, else the picture the engine sends along.
        let icon = (request["appPath"] as? String).map { NSWorkspace.shared.icon(forFile: $0) }
            ?? (request["icon"] as? String).flatMap { $0.components(separatedBy: ",").last }.flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:))
            ?? tab.favicon
        let name = (app as NSString).deletingPathExtension
        var buttons: [PromptCard.Button] = [.init(title: L("common.cancel"), style: .plain) { _ in resolve(false, false) }]
        // "Always" only where the engine can remember it (a page with an origin).
        if !(request["remember"] is NSNull), request["remember"] != nil {
            buttons.append(.init(title: L("externalApp.always"), style: .secondary) { _ in resolve(true, true) })
        }
        buttons.append(.init(title: L("externalApp.open"), style: .primary) { _ in resolve(true, false) })
        add(.init(id: "app-\(id)", tab: tab, belongsToTab: true, icon: icon, host: host,
                  title: L("externalApp.title", name), buttons: buttons, dismissed: { resolve(false, false) }))
    }
}
