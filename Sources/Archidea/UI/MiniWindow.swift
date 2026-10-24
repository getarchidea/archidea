import AppKit
import ArchideaCore
import ArdiaCore

/// A small window for a link from another app (a chat, a mail): one page, no sidebar, gone when closed. The page
/// can move into the browser window as it is, scroll position, sign-in and all ("Open in Archidea").
final class MiniWindowController: NSObject, ArdiaCoreWindowDelegate, ArdiaCoreTabDelegate {
    let coreWindow: ArdiaCoreWindow
    let tab: ArdiaCoreTab
    private let profile: ArdiaCoreProfile
    private let root = MiniRootView()
    private let page = ContentView()
    private let bar = MiniToolbar()
    private let loadingBar = LoadingBar(frame: .zero)
    private lazy var sitePrompts = SitePrompts(host: page, activeTab: { [weak self] in self?.tab })
    /// Set once the page has moved to the browser window: closing this one then leaves the page alone.
    private var handedOver = false
    private var onClose: (MiniWindowController) -> Void

    var window: NSWindow { coreWindow.window }

    static let size = NSSize(width: 1000, height: 720)
    /// Marks the window as one of ours, so the browser window leaves it the keyboard.
    static let identifier = NSUserInterfaceItemIdentifier("archidea.mini")

    init(url: String, profile: ArdiaCoreProfile, cascadeFrom previous: NSWindow?, onClose: @escaping (MiniWindowController) -> Void) {
        self.profile = profile
        self.onClose = onClose
        coreWindow = ArdiaCoreWindow(contentRect: NSRect(origin: .zero, size: Self.size))
        coreWindow.prepare(profile)
        coreWindow.activeProfile = profile
        tab = coreWindow.openTab(url, profile: profile, foreground: true)
        super.init()
        coreWindow.delegate = self
        tab.delegate = self
        configureWindow(cascadeFrom: previous)
        buildViews()
    }

    private func configureWindow(cascadeFrom previous: NSWindow?) {
        window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.identifier = Self.identifier
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 480, height: 360)
        window.setContentSize(Self.size)
        if let previous {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: previous.frame.minX, y: previous.frame.maxY)))
        } else if let screen = NSScreen.main?.visibleFrame {
            // A little above the middle of the screen, where the eye already is after clicking a link.
            window.setFrameOrigin(NSPoint(x: screen.midX - window.frame.width / 2, y: screen.midY - window.frame.height / 2 + screen.height * 0.06))
        }
    }

    /// Into the engine's host view, like the browser window: the window's content view also holds the engine's
    /// own view, which lies on top and would take every click.
    private func buildViews() {
        let host = coreWindow.hostView
        root.frame = host.bounds
        root.autoresizingMask = [.width, .height]
        host.addSubview(root)
        root.addSubview(bar)
        root.addSubview(page)
        root.addSubview(loadingBar)
        root.onLayout = { [weak self] in self?.layout() }
        page.addSubview(tab.view)
        bar.onOpen = { [weak self] in self?.openInBrowser() }
        bar.onCopy = { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tab.url, forType: .string)
            bar.flashCopied()
        }
        update()
    }

    private func layout() {
        let bounds = root.bounds
        let barHeight: CGFloat = 40
        let gap: CGFloat = 6
        bar.frame = NSRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: barHeight)
        page.frame = NSRect(x: gap, y: gap, width: bounds.width - gap * 2, height: bounds.height - barHeight - gap)
        tab.view.frame = page.bounds
        let size = LoadingBar.size
        loadingBar.frame = NSRect(x: page.frame.midX - size.width / 2, y: page.frame.maxY + 2, width: size.width, height: size.height)
    }

    /// Coming from another app, AppKit gives the keyboard back to the window that had it last (the browser
    /// window) once activation completes; the mini window takes it after that.
    func show() {
        tab.noteShown(byHost: true)
        window.makeKeyAndOrderFront(nil)
        guard !NSApp.isActive else { return takeKeyboard() }
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            activation.map(NotificationCenter.default.removeObserver)
            activation = nil
            DispatchQueue.main.async { self.takeKeyboard() }
        }
        NSApp.activate()
    }

    private var activation: NSObjectProtocol?

    private func takeKeyboard() {
        window.makeKeyAndOrderFront(nil)
        tab.focus()
        Trace.log("mini window: key=\(window.isKeyWindow), app active=\(NSApp.isActive)")
    }

    private func update() {
        bar.show(title: tab.title, url: tab.url, icon: tab.favicon, secure: (tab.securityInfo["level"] as? String) == "secure")
        loadingBar.show(loading: tab.loading, progress: tab.progress)
    }

    // MARK: open in the browser window

    /// The page moves into the browser window's current space as a new tab, and this window goes.
    func openInBrowser() {
        guard !handedOver, let browser = (NSApp.delegate as? AppDelegate)?.windowController else { return }
        handedOver = true
        sitePrompts.dismissAll()
        tab.delegate = nil
        browser.adoptPage(tab)
        window.orderOut(nil)
        // The engine lets go of the page on its next turn; the window closes after that, empty.
        DispatchQueue.main.async { [weak self] in self?.close() }
    }

    func close() {
        coreWindow.delegate = nil
        if !handedOver { tab.delegate = nil }
        coreWindow.close()
        onClose(self)
    }

    /// The engine took a permission request back.
    func dismissPermissionRequest(_ id: String) { sitePrompts.remove(id: id) }

    func showPermissionRequest(_ request: [String: Any], tab: ArdiaCoreTab) { sitePrompts.addPermissionRequest(request, tab: tab) }

    // MARK: ArdiaCoreWindowDelegate

    @objc(windowShouldClose:)
    func windowShouldClose(_ window: ArdiaCoreWindow) -> Bool {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            coreWindow.delegate = nil
            onClose(self)
        }
        return true
    }

    @objc(window:handleKeyEvent:)
    func window(_ window: ArdiaCoreWindow, handleKeyEvent event: NSEvent) -> Bool {
        NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }

    /// A link the page opens in a new tab goes to the browser window; this one keeps showing its one page.
    @objc(window:didInsertTab:opener:disposition:)
    func window(_ window: ArdiaCoreWindow, didInsert inserted: ArdiaCoreTab, opener: ArdiaCoreTab?, disposition: String) {
        guard inserted !== tab, let browser = (NSApp.delegate as? AppDelegate)?.windowController else { return }
        browser.adoptPage(inserted, foreground: !TabRuntime.opensInBackground(disposition))
    }

    @objc(window:passwordPrompt:forTab:)
    func window(_ window: ArdiaCoreWindow, passwordPrompt prompt: [String: Any], for tab: ArdiaCoreTab) {
        sitePrompts.addPasswordPrompt(prompt, tab: tab)
    }

    @objc(window:tab:didChangeFullscreen:)
    func window(_ window: ArdiaCoreWindow, tab: ArdiaCoreTab, didChangeFullscreen fullscreen: Bool) {
        if fullscreen != self.window.styleMask.contains(.fullScreen) { self.window.toggleFullScreen(nil) }
    }

    // MARK: ArdiaCoreTabDelegate

    @objc(tabDidChangeTitle:) func tabDidChangeTitle(_ tab: ArdiaCoreTab) { update() }
    @objc(tabDidChangeURL:) func tabDidChangeURL(_ tab: ArdiaCoreTab) { update() }
    @objc(tabDidChangeFavicon:) func tabDidChangeFavicon(_ tab: ArdiaCoreTab) { update() }
    @objc(tabDidChangeLoading:) func tabDidChangeLoading(_ tab: ArdiaCoreTab) { update() }
    @objc(tabDidChangeProgress:) func tabDidChangeProgress(_ tab: ArdiaCoreTab) { loadingBar.show(loading: tab.loading, progress: tab.progress) }

    @objc(tab:externalAppRequest:)
    func tab(_ tab: ArdiaCoreTab, externalAppRequest request: [String: Any]) {
        sitePrompts.addExternalAppRequest(request, tab: tab)
    }

    /// The page closed itself (a sign-in finishing with `window.close()`): so does its window.
    @objc(tabWillClose:)
    func tabWillClose(_ tab: ArdiaCoreTab) {
        guard !handedOver else { return }
        window.orderOut(nil)
        DispatchQueue.main.async { [weak self] in self?.close() }
    }

    /// A link that only downloads a file leaves nothing to show.
    @objc(tab:navigationBecameDownload:)
    func tab(_ tab: ArdiaCoreTab, navigationBecameDownload url: String) {
        guard !tab.canGoBack, tab.url.isEmpty || tab.url == "about:blank" || tab.url == url else { return }
        window.orderOut(nil)
        DispatchQueue.main.async { [weak self] in self?.close() }
    }
}

#if DRIFT_DEV
extension MiniWindowController {
    /// The "Open in Archidea" button's centre and a point in the page, in window coordinates.
    var debugPoints: (button: NSPoint, page: NSPoint) {
        let open = bar.subviews.first { NSStringFromClass(type(of: $0)).contains("MiniOpenButton") }!
        let button = open.convert(NSPoint(x: open.bounds.midX, y: open.bounds.midY), to: nil)
        return (button, page.convert(NSPoint(x: page.bounds.midX, y: page.bounds.midY), to: nil))
    }
}
#endif

/// The mini window's backdrop: the window's own material, the page laid on it like in the browser window.
private final class MiniRootView: NSVisualEffectView {
    var onLayout: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .underWindowBackground
        blendingMode = .behindWindow
        state = .followsWindowActiveState
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// Site, address and the two actions, beside the traffic lights.
private final class MiniToolbar: NSView, WindowDragSurface {
    var onOpen: (() -> Void)?
    var onCopy: (() -> Void)?

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let host = NSTextField(labelWithString: "")
    private let copy = ChromeButton(symbol: "link", tip: L("mini.copyLink"))
    private let open = MiniOpenButton(title: L("mini.open"))
    private var copiedReset: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        host.font = .systemFont(ofSize: 12)
        host.textColor = .secondaryLabelColor
        host.lineBreakMode = .byTruncatingMiddle
        copy.target = self
        copy.action = #selector(copyTapped)
        open.onClick = { [weak self] in self?.onOpen?() }
        [icon, title, host, copy, open].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(title text: String, url: String, icon image: NSImage?, secure: Bool) {
        let parsed = URL(string: url)
        let site = parsed?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? url
        title.stringValue = text.isEmpty ? site : text
        host.stringValue = site
        host.isHidden = text.isEmpty || text == site
        icon.image = image ?? NSImage(systemSymbolName: secure ? "lock.fill" : "globe", accessibilityDescription: nil)
        icon.contentTintColor = image == nil ? .secondaryLabelColor : nil
        needsLayout = true
    }

    func flashCopied() {
        copy.setSymbol("checkmark", size: 13)
        copiedReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in self?.copy.setSymbol("link", size: 14) }
        copiedReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: reset)
    }

    @objc private func copyTapped() { onCopy?() }

    override func layout() {
        super.layout()
        let midY = bounds.midY
        let openSize = open.fittingSize
        open.frame = NSRect(x: bounds.width - 10 - openSize.width, y: midY - openSize.height / 2, width: openSize.width, height: openSize.height)
        copy.frame = NSRect(x: open.frame.minX - 6 - 28, y: midY - 14, width: 28, height: 28)
        // Past the traffic lights.
        let start: CGFloat = 84
        icon.frame = NSRect(x: start, y: midY - 8, width: 16, height: 16)
        let textX = icon.frame.maxX + 8
        let room = max(0, copy.frame.minX - 12 - textX)
        let titleWidth = min(ceil(title.attributedStringValue.size().width) + 4, host.isHidden ? room : room * 0.62)
        title.frame = NSRect(x: textX, y: midY - 9, width: titleWidth, height: 18)
        host.frame = NSRect(x: title.frame.maxX + 8, y: midY - 8, width: max(0, room - titleWidth - 8), height: 16)
    }
}

/// "Open in Archidea": a quiet capsule that fills on hover.
private final class MiniOpenButton: NSView {
    var onClick: (() -> Void)?
    private let label: NSTextField
    private let glyph = NSImageView(image: NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)!
        .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))!)
    private var hovering = false { didSet { needsDisplay = true } }

    init(title: String) {
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        glyph.contentTintColor = .labelColor
        addSubview(glyph)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var labelWidth: CGFloat { ceil(label.attributedStringValue.size().width) + 2 }

    override var fittingSize: NSSize { NSSize(width: labelWidth + 44, height: 26) }

    /// The whole capsule is the button, label and glyph included.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func layout() {
        super.layout()
        glyph.frame = NSRect(x: 11, y: (bounds.height - 14) / 2, width: 14, height: 14)
        label.frame = NSRect(x: 31, y: (bounds.height - 16) / 2, width: labelWidth, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        (hovering ? Theme.addressHover : Theme.addressFill).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        Theme.hairline.setStroke()
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2 - 0.5, yRadius: bounds.height / 2 - 0.5)
        edge.lineWidth = 1
        edge.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}
