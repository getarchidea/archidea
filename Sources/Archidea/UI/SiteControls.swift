import AppKit
import ArchideaCore
import ArdiaCore

/// Arc-style site controls behind the address bar's sliders button: quick actions, extensions, zoom,
/// the site's permissions, clearing its data, and the full-URL switch. Permissions and site data go through
/// the engine's own Chrome services (`ac_site_settings_*`, `ac_site_data_clear`).
final class SiteControls: NSViewController {
    private weak var controller: BrowserWindowController?
    private let tab: ArdiaCoreTab
    private var popover: NSPopover?
    private let zoomLabel = NSTextField(labelWithString: "")
    private var permissionPopups: [String: NSPopUpButton] = [:]

    private static let width: CGFloat = 316
    private static let permissions: [(type: String, symbol: String, values: [String])] = [
        ("camera", "video", ["ask", "allow", "block"]),
        ("microphone", "mic", ["ask", "allow", "block"]),
        ("location", "location", ["ask", "allow", "block"]),
        ("notifications", "bell", ["ask", "allow", "block"]),
        ("popups", "macwindow.on.rectangle", ["allow", "block"]),
        ("sound", "speaker.wave.2", ["allow", "block"]),
    ]

    init(controller: BrowserWindowController, tab: ArdiaCoreTab) {
        self.controller = controller
        self.tab = tab
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var origin: String? {
        guard let url = URL(string: tab.url), let scheme = url.scheme, ["http", "https"].contains(scheme), let host = url.host else { return nil }
        return url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)

        let actions = NSStackView(views: [
            ActionTile(symbol: "square.and.arrow.up", tip: L("site.share")) { [weak self] tile in self?.share(from: tile) },
            ActionTile(symbol: "link", tip: L("site.copyLink")) { [weak self] _ in self?.copyLink() },
            ActionTile(symbol: "magnifyingglass", tip: L("site.find")) { [weak self] _ in self?.close { $0.showFind() } },
            ActionTile(symbol: "hammer", tip: L("site.devTools")) { [weak self] _ in self?.close { $0.toggleDevTools() } },
        ])
        actions.distribution = .fillEqually
        actions.spacing = 8
        add(actions, to: stack)

        stack.addArrangedSubview(sectionLabel(L("site.extensions")))
        // Every extension gets a tile, five to a row, then the Web Store's.
        var tiles: [NSView] = []
        for ext in controller?.profile.extensions ?? [] {
            guard let id = ext["id"] as? String else { continue }
            let tile = ActionTile(symbol: "puzzlepiece.extension", tip: ext["name"] as? String ?? id, width: 44) { [weak self] _ in
                self?.close { $0.extensions.openPopup(extensionId: id, from: nil, userClicked: true) }
            }
            if let image = ExtensionIcons.image(for: id, path: ext["path"] as? String) { tile.setImage(image) }
            tiles.append(tile)
        }
        tiles.append(ActionTile(symbol: "plus", tip: L("menu.webStore"), width: 44) { [weak self] _ in
            self?.close { $0.openInNewTab("https://chromewebstore.google.com/category/extensions") }
        })
        let extensions = NSStackView()
        extensions.orientation = .vertical
        extensions.alignment = .leading
        extensions.spacing = 8
        for start in stride(from: 0, to: tiles.count, by: 5) {
            let row = NSStackView(views: Array(tiles[start..<min(start + 5, tiles.count)]))
            row.spacing = 8
            extensions.addArrangedSubview(row)
        }
        stack.addArrangedSubview(extensions)

        stack.addArrangedSubview(sectionLabel(L("site.settings")))
        let zoomOut = ActionTile(symbol: "minus", tip: L("menu.zoomOut"), width: 26, height: 22) { [weak self] _ in self?.zoom(-1) }
        let zoomIn = ActionTile(symbol: "plus", tip: L("menu.zoomIn"), width: 26, height: 22) { [weak self] _ in self?.zoom(1) }
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        zoomLabel.alignment = .center
        zoomLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let zoomControl = NSStackView(views: [zoomOut, zoomLabel, zoomIn])
        zoomControl.spacing = 4
        updateZoom()
        var rows: [NSView] = []
        if AdBlocker.isAvailable {
            let blocker = NSSwitch()
            blocker.controlSize = .small
            blocker.state = controller?.settings.adBlock == true ? .on : .off
            blocker.target = self
            blocker.action = #selector(adBlockChanged(_:))
            let count = controller?.runtime.blockedCount(for: tab) ?? 0
            let title = blocker.state == .on && count > 0 ? L("site.adBlock.count", count) : L("site.adBlock")
            rows.append(ControlRow(symbol: "shield.lefthalf.filled", title: title, control: blocker))
        }
        rows.append(ControlRow(symbol: "plus.magnifyingglass", title: L("site.zoom"), control: zoomControl))

        if let origin {
            for permission in Self.permissions {
                let popup = NSPopUpButton(frame: .zero, pullsDown: false)
                popup.isBordered = false
                popup.controlSize = .small
                popup.font = .systemFont(ofSize: 12)
                for value in permission.values {
                    popup.addItem(withTitle: L("site.value.\(value)"))
                    popup.lastItem?.representedObject = value
                }
                popup.isEnabled = false
                popup.target = self
                popup.action = #selector(permissionChanged(_:))
                popup.identifier = NSUserInterfaceItemIdentifier(permission.type)
                permissionPopups[permission.type] = popup
                rows.append(ControlRow(symbol: permission.symbol, title: L("site.permission.\(permission.type)"), control: popup))
            }
            loadPermissions(origin)
        }
        let card = SettingsCard(rows: rows)
        add(card, to: stack)

        var footer: [NSView] = []
        if origin != nil {
            footer.append(LinkRow(symbol: "trash", title: L("site.clearData")) { [weak self] in self?.clearSiteData() })
        }
        let fullURL = NSSwitch()
        fullURL.controlSize = .small
        fullURL.state = controller?.settings.showFullURL == true ? .on : .off
        fullURL.target = self
        fullURL.action = #selector(fullURLChanged(_:))
        footer.append(ControlRow(symbol: "text.alignleft", title: L("site.showFullURL"), control: fullURL))
        add(SettingsCard(rows: footer), to: stack)

        let security = tab.securityInfo
        let level = security["level"] as? String ?? "none"
        let secure = level == "secure"
        var text = secure ? L("site.secure") : level == "certificateError" ? L("site.certificateError") : L("site.notSecure")
        if secure, let issuer = ((security["certificate"] as? [String: Any])?["issuer"] as? [String: Any]),
           let name = (issuer["organizations"] as? [String])?.first ?? issuer["commonName"] as? String, !name.isEmpty {
            text += " · " + name
        }
        let badge = Badge(symbol: secure ? "lock.fill" : "exclamationmark.triangle", text: text)
        // The certificate opens in macOS's certificate viewer, like Safari's.
        if let url = URL(string: tab.url), url.scheme == "https" {
            badge.onClick = { [weak self] in
                guard let self, let window = controller?.window else { return }
                popover?.close()
                CertificateViewer.show(for: url, in: window)
            }
            badge.toolTip = L("site.showCertificate")
        }
        stack.addArrangedSubview(badge)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        view.layoutSubtreeIfNeeded()
        preferredContentSize = stack.fittingSize
    }

    private func add(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    func present(from view: NSView) {
        let popover = NSPopover()
        popover.contentViewController = self
        popover.behavior = .transient
        self.popover = popover
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    private func close(then action: (BrowserWindowController) -> Void) {
        popover?.close()
        if let controller { action(controller) }
    }

    // MARK: actions

    private func share(from view: NSView) {
        guard let url = URL(string: tab.url) else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    private func copyLink() {
        controller?.copyURL()
        popover?.close()
    }

    private func zoom(_ step: Int32) {
        tab.zoomStep(step)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.updateZoom() }
    }

    private func updateZoom() {
        zoomLabel.stringValue = "\(Int((tab.zoomFactor * 100).rounded()))%"
    }

    private func loadPermissions(_ origin: String) {
        guard let profile = controller?.profile else { return }
        EngineCall.call("ac_site_settings_get", profile: profile, args: ["origin": origin]) { [weak self] reply in
            guard let self, let settings = reply?["settings"] as? [String: [String: Any]] else { return }
            for (type, popup) in permissionPopups {
                let value = settings[type]?["value"] as? String ?? "ask"
                if let index = popup.itemArray.firstIndex(where: { $0.representedObject as? String == value }) { popup.selectItem(at: index) }
                popup.isEnabled = settings[type] != nil
            }
        }
    }

    @objc private func permissionChanged(_ sender: NSPopUpButton) {
        guard let origin, let profile = controller?.profile, let type = sender.identifier?.rawValue,
              let value = sender.selectedItem?.representedObject as? String else { return }
        EngineCall.call("ac_site_settings_set", profile: profile, args: ["origin": origin, "type": type, "value": value]) { reply in
            Trace.log("site setting \(type)=\(value): \(reply ?? [:])")
        }
        if type == "sound" { tab.muted = value == "block" }
    }

    private func clearSiteData() {
        guard let origin, let controller else { return }
        let profile = controller.profile
        let host = URL(string: origin)?.host ?? origin
        popover?.close()
        controller.confirm(host: host, icon: tab.favicon, title: L("site.clearData.title", host), detail: L("site.clearData.text"),
                           confirm: L("site.clearData.confirm")) { [weak tab] in
            EngineCall.call("ac_site_data_clear", profile: profile, args: ["origin": origin]) { reply in
                Trace.log("cleared a site's data: \(reply ?? [:])")
                tab?.reload()
            }
        }
    }

    @objc private func adBlockChanged(_ sender: NSSwitch) {
        guard let controller else { return }
        let on = sender.state == .on
        controller.updateSettings { $0.adBlock = on }
        tab.reload()
    }

    @objc private func fullURLChanged(_ sender: NSSwitch) {
        guard let controller else { return }
        let on = sender.state == .on
        controller.updateSettings { $0.showFullURL = on }
    }
}

// MARK: - pieces

private final class ActionTile: NSView {
    private let icon = NSImageView()
    private let action: (ActionTile) -> Void
    private var hovering = false { didSet { needsDisplay = true } }

    init(symbol: String, tip: String, width: CGFloat? = nil, height: CGFloat = 40, action: @escaping (ActionTile) -> Void) {
        self.action = action
        super.init(frame: .zero)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        icon.imageScaling = .scaleNone
        icon.contentTintColor = .labelColor
        addSubview(icon)
        toolTip = tip
        if let width { widthAnchor.constraint(equalToConstant: width).isActive = true }
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ source: NSImage) {
        let image = source.copy() as? NSImage ?? source
        image.size = NSSize(width: 20, height: 20)
        icon.image = image
        icon.imageScaling = .scaleProportionallyDown
        needsLayout = true
    }

    override func layout() {
        super.layout()
        icon.frame = icon.imageScaling == .scaleNone ? bounds : bounds.insetBy(dx: (bounds.width - 20) / 2, dy: (bounds.height - 20) / 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        (hovering ? Theme.addressHover : Theme.keycap).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { action(self) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Icon and title on the left, a control on the right; a compact settings row.
private final class ControlRow: NSView {
    init(symbol: String, title: String, control: NSView) {
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))!)
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleNone
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        for view in [icon, label, control] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -8),
            control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

private final class LinkRow: NSView {
    private let action: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }

    init(symbol: String, title: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        let row = ControlRow(symbol: symbol, title: title, control: NSView())
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        Theme.hover.setFill()
        bounds.fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { action() }
}

private final class Badge: NSView {
    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = onClick != nil }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    init(symbol: String, text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))!)
        icon.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 9)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = (hovering ? Theme.addressHover : Theme.keycap).cgColor }
}
