import AppKit

/// Extension list and action popups. The popup is a real extension page hosted in an NSPopover.
final class ExtensionsController: NSObject, ArdiaCoreTabDelegate {
    private weak var controller: BrowserWindowController?
    private var popupTab: ArdiaCoreTab?
    private weak var lastAnchor: NSView?

    init(controller: BrowserWindowController) {
        self.controller = controller
    }

    private var installed: [[String: Any]] {
        (controller?.profile.extensions ?? []).sorted {
            ($0["name"] as? String ?? "").localizedCaseInsensitiveCompare($1["name"] as? String ?? "") == .orderedAscending
        }
    }

    func showMenu(from view: NSView) {
        lastAnchor = view
        let menu = NSMenu()
        let list = installed
        if list.isEmpty {
            let empty = NSMenuItem(title: L("extensions.none"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for ext in list {
            guard let id = ext["id"] as? String else { continue }
            let item = ClosureMenuItem(ext["name"] as? String ?? id) { [weak self] in
                self?.openPopup(extensionId: id, from: view, userClicked: true)
            }
            let icon = ExtensionIcons.image(for: id, path: ext["path"] as? String)?.copy() as? NSImage
            icon?.size = NSSize(width: 16, height: 16)
            item.image = icon ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Chrome Web Store") { [weak self] in
            self?.controller?.openInNewTab("https://chromewebstore.google.com/category/extensions")
        })
        menu.addItem(ClosureMenuItem(L("extensions.manage")) { [weak self] in
            self?.controller?.openInNewTab("chrome://extensions")
        })
        menu.autoenablesItems = false
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    func openPopup(extensionId id: String, from view: NSView?, userClicked: Bool = false) {
        guard let controller else { return }
        host?.close()
        let tab = controller.activeTab
        if userClicked, let tab {
            let result = tab.executeExtensionAction(id)
            if result == "none" || result == "sidePanel" { return }
        }
        var url = ""
        if let tab, let state = tab.actionStates(forExtensions: [id])[id] as? [String: Any] {
            url = state["popup"] as? String ?? ""
        }
        if url.isEmpty {
            url = installed.first { $0["id"] as? String == id }?["actionPopupURL"] as? String ?? ""
        }
        guard !url.isEmpty,
              let page = controller.coreWindow.openExtensionView(url, profile: controller.profile, kind: "popup") else { return }
        page.delegate = self
        popupTab = page
        // Inside the browser window: an extension page in a separate popover window gets its
        // pointer positions wrong (menus whose hover lands somewhere else), since Chrome maps them to the browser window.
        let root = controller.overlayHost
        let anchor = (view ?? lastAnchor).flatMap { $0.window === root.window ? root.convert($0.bounds, from: $0) : nil }
        let popup = ExtensionPopupHost(page: page, anchor: anchor)
        popup.onClose = { [weak self] in self?.closed() }
        popup.frame = root.bounds
        root.addSubview(popup)
        host = popup
        page.focus()
    }

    private weak var host: ExtensionPopupHost?

    /// Closes an open popup (its key monitor goes with it).
    func closePopup() { host?.close() }

    private func closed() {
        popupTab?.delegate = nil
        if let page = popupTab, !page.closed { page.close() }
        popupTab = nil
        host = nil
    }

    @objc(tab:preferredSizeDidChange:)
    func tab(_ tab: ArdiaCoreTab, preferredSizeDidChange size: NSSize) {
        guard tab === popupTab, size.width > 0, size.height > 0 else { return }
        host?.contentSize = NSSize(width: min(max(size.width, 25), 800), height: min(max(size.height, 25), 600))
    }

    @objc(tabWillClose:)
    func tabWillClose(_ tab: ArdiaCoreTab) {
        guard tab === popupTab else { return }
        popupTab = nil
        host?.close()
    }
}

/// An extension's popup laid over the browser window: a card next to its anchor, closed by a click outside or Escape.
final class ExtensionPopupHost: NSView {
    var onClose: (() -> Void)?
    var contentSize = NSSize(width: 360, height: 480) { didSet { needsLayout = true } }
    private let page: ArdiaCoreTab
    private let anchor: NSRect?
    private let shadowView = NSView()
    private let card = NSView()
    private var keyMonitor: Any?

    init(page: ArdiaCoreTab, anchor: NSRect?) {
        self.page = page
        self.anchor = anchor
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        shadowView.wantsLayer = true
        shadowView.layer?.shadowColor = NSColor.black.cgColor
        shadowView.layer?.shadowOpacity = 0.3
        shadowView.layer?.shadowRadius = 22
        shadowView.layer?.shadowOffset = CGSize(width: 0, height: -8)
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1
        addSubview(shadowView)
        shadowView.addSubview(card)
        page.view.removeFromSuperview()
        card.addSubview(page.view)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, event.window === window else { return event }
            close()
            return nil
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        card.layer?.backgroundColor = Theme.page.cgColor
        card.layer?.borderColor = Theme.hairline.cgColor
    }

    override func layout() {
        super.layout()
        let size = contentSize
        var origin: NSPoint
        if let anchor {
            let below = anchor.midY > bounds.midY
            origin = NSPoint(x: anchor.minX, y: below ? anchor.minY - 6 - size.height : anchor.maxY + 6)
        } else {
            origin = NSPoint(x: 16, y: bounds.height - 60 - size.height)
        }
        origin.x = max(8, min(origin.x, bounds.width - size.width - 8))
        origin.y = max(8, min(origin.y, bounds.height - size.height - 8))
        shadowView.frame = NSRect(origin: origin, size: size)
        shadowView.layer?.shadowPath = CGPath(roundedRect: shadowView.bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
        card.frame = shadowView.bounds
        page.view.frame = card.bounds
    }

    override func mouseDown(with event: NSEvent) {
        if !shadowView.frame.contains(convert(event.locationInWindow, from: nil)) { close() }
    }

    func close() {
        guard superview != nil else { return }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        removeFromSuperview()
        onClose?()
    }
}
