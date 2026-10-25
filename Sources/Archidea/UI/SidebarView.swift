import AppKit
import ArchideaCore
import ArdiaCore

protocol SidebarViewDelegate: AnyObject {
    func sidebarSelect(_ item: SidebarItem, cause: String)
    func sidebarDownloads(from view: NSView)
    func sidebarClose(_ item: SidebarItem)
    func sidebarRemove(_ item: SidebarItem)
    func sidebarTogglePin(_ item: SidebarItem)
    func sidebarResetPin(_ item: SidebarItem)
    func sidebarDeleteFolder(_ folder: SidebarItem)
    func sidebarMove(_ item: SidebarItem, to space: Space)
    func sidebarNewTab()
    func sidebarNewFolder()
    func sidebarClearToday()
    func sidebarClearableCount() -> Int
    func sidebarClosedCount() -> Int
    func sidebarReopenClosed()
    func sidebarEditTheme(_ space: Space, from view: NSView)
    func sidebarManageSpaces()
    func sidebarAddressClicked()
    func sidebarCopyURL()
    func sidebarSiteControls(from view: NSView)
    func sidebarBack()
    func sidebarForward()
    func sidebarReload()
    func sidebarToggle()
    func sidebarSwitch(to space: Space)
    func sidebarNewSpace()
    func sidebarRename(_ space: Space)
    func sidebarDelete(_ space: Space)
    func sidebarRestyle(_ space: Space, color: String?, symbol: String?)
    func sidebarExtensions(from view: NSView)
    func sidebarChanged()
    func sidebarFavicon(for item: SidebarItem) -> NSImage?
    func sidebarIsLoaded(_ item: SidebarItem) -> Bool
    func sidebarIsLoading(_ item: SidebarItem) -> Bool
    func sidebarCanSplit(_ item: SidebarItem) -> Bool
    func sidebarSplit(_ item: SidebarItem)
    func sidebarSeparate(_ split: SidebarItem)
    /// A split's tab closes from its own button: it leaves the split.
    func sidebarClosePane(_ item: SidebarItem)
    func sidebarSwapSides(_ split: SidebarItem)
    func sidebarDragBegan()
    func sidebarDragEnded()
}

final class SidebarMarker {
    enum Kind { case divider, newTab }
    let kind: Kind
    private init(_ kind: Kind) { self.kind = kind }
    static let divider = SidebarMarker(.divider)
    static let newTab = SidebarMarker(.newTab)
}

/// The sidebar: its toolbar, the address, the space's header and bar, and around them the list of the space's tabs
/// (`SidebarList`), which does the list's own work. This view holds the chrome and lays it all out.
final class SidebarView: NSView, WindowDragSurface {
    static let itemType = SidebarList.itemType
    /// Where a drop goes in the list: the model's own lists.
    typealias Container = Space.Slot

    weak var delegate: SidebarViewDelegate? {
        didSet { list.delegate = delegate }
    }
    private let store: Store
    private let windowState: WindowState
    private var space: Space { store.state.space(shownIn: windowState) }
    /// The pins and Today.
    let list: SidebarList
    private var outline: SidebarOutline { list.outline }
    private var scroll: ThinScrollView { list.scroll }

    private let card = CardBackground()
    /// Holds the header and the list, and clips them to the sidebar while they slide to another space.
    private let slideClip = SlideClip()
    private let cardTint = CardTint()
    private let toggleButton = ChromeButton(symbol: "sidebar.left", tip: L("sidebar.toggle.tip"))
    private let backButton = ChromeButton(symbol: "arrow.left", tip: L("sidebar.back.tip"))
    private let forwardButton = ChromeButton(symbol: "arrow.right", tip: L("sidebar.forward.tip"))
    private let reloadButton = ChromeButton(symbol: "arrow.clockwise", tip: L("sidebar.reload.tip"))
    private let address = AddressPill()
    private let header = SpaceHeader()
    private let extensionsButton = ChromeButton(symbol: "puzzlepiece.extension", tip: L("sidebar.extensions.tip"))
    private let addSpaceButton = ChromeButton(symbol: "plus", tip: L("sidebar.newSpace.tip"))
    /// Next to the extensions button once there's something downloaded or downloading.
    let downloadsButton = DownloadsButton()
    private let spaceStack = NSStackView()
    private let updateBanner = UpdateBanner()
    private var updateVersion: String?
    /// Holds the space buttons; scrolls sideways once even their compact dots don't fit.
    private let spaceStrip = SpaceStrip()

    /// Floating: a hidden sidebar shown over the page, drawn as its own card.
    var floating = false {
        didSet {
            guard floating != oldValue else { return }
            card.isHidden = !floating
            layer?.shadowOpacity = floating ? 1 : 0
            needsLayout = true
        }
    }

    var tintStrength: CGFloat = Theme.tintAlpha
    var tint: NSColor? {
        didSet { cardTint.layer?.backgroundColor = tint?.withAlphaComponent(tintStrength).cgColor }
    }

    override var isFlipped: Bool { true }

    init(store: Store, window windowState: WindowState) {
        self.store = store
        self.windowState = windowState
        list = SidebarList(store: store, window: windowState)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.35).cgColor
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        layer?.shadowOpacity = 0

        card.material = .sidebar
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 0
        card.isHidden = true
        cardTint.wantsLayer = true
        card.addSubview(cardTint)
        addSubview(card)

        for (button, action) in [(toggleButton, #selector(toggleTapped)), (backButton, #selector(backTapped)),
                                 (forwardButton, #selector(forwardTapped)), (reloadButton, #selector(reloadTapped)),
                                 (extensionsButton, #selector(extensionsTapped)), (addSpaceButton, #selector(addSpaceTapped)),
                                 (downloadsButton, #selector(downloadsTapped))] {
            button.target = self
            button.action = action
            addSubview(button)
        }
        downloadsButton.isHidden = true

        address.onClick = { [weak self] in self?.delegate?.sidebarAddressClicked() }
        address.onCopy = { [weak self] in
            self?.delegate?.sidebarCopyURL()
            self?.address.flashCopied()
        }
        address.onSiteControls = { [weak self] anchor in self?.delegate?.sidebarSiteControls(from: anchor) }
        addSubview(address)

        header.dropTarget = { [weak self] info in
            guard let self, let item = list.draggedItem(info) else { return false }
            return list.move(item, to: .pinned, at: 0)
        }
        header.onClick = { [weak self] in
            guard let self else { return }
            spaceMenu(for: space, anchor: header).popUp(positioning: nil, at: NSPoint(x: 0, y: header.bounds.height + 2), in: header)
        }
        addSubview(slideClip)
        slideClip.addSubview(header)

        list.emptyAreaMenu = { [weak self] in
            guard let self else { return NSMenu() }
            return spaceMenu(for: space, anchor: header, withTabItems: true)
        }
        slideClip.addSubview(scroll)

        spaceStack.orientation = .horizontal
        spaceStack.spacing = 2
        spaceStrip.documentView = spaceStack
        addSubview(spaceStrip)
        updateBanner.isHidden = true
        addSubview(updateBanner)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        card.layer?.borderColor = Theme.hairline.cgColor
    }

    override func layout() {
        super.layout()
        let width = bounds.width, height = bounds.height
        card.frame = bounds
        cardTint.frame = card.bounds
        // As big as the sidebar, so what's inside has the sidebar's own coordinates.
        slideClip.frame = bounds
        slideClip.layer?.cornerRadius = floating ? 10 : 0
        layer?.shadowPath = floating ? CGPath(roundedRect: bounds, cornerWidth: 10, cornerHeight: 10, transform: nil) : nil

        // The traffic lights stay where the window puts them; the toolbar lines up with them.
        let origin: CGFloat = floating ? RootView.overlayInset : 0
        let rowY = TrafficLights.centerY - origin - 13
        var x = 84 - origin
        for button in [toggleButton, backButton, forwardButton] {
            button.frame = NSRect(x: x, y: rowY, width: 28, height: 26)
            x += 30
        }
        reloadButton.frame = NSRect(x: width - 40, y: rowY, width: 28, height: 26)

        let top = TrafficLights.centerY - origin + 20
        address.frame = NSRect(x: 12, y: top, width: width - 24, height: 38)
        header.frame = NSRect(x: 12, y: top + 48, width: width - 24, height: 28)
        let listTop = top + 80
        let banner: CGFloat = updateVersion == nil ? 0 : 58
        scroll.frame = NSRect(x: 0, y: listTop, width: width, height: max(0, height - listTop - 48 - banner))
        updateBanner.frame = NSRect(x: 10, y: height - 48 - banner + 4, width: width - 20, height: max(0, banner - 8))
        list.didLayout()

        let barY = height - 40
        extensionsButton.frame = NSRect(x: 12, y: barY, width: 28, height: 28)
        downloadsButton.frame = NSRect(x: 42, y: barY, width: 28, height: 28)
        addSpaceButton.frame = NSRect(x: width - 40, y: barY, width: 28, height: 28)
        layoutSpaces(barY: barY)
    }


    // MARK: public

    var addressAnchor: NSView { address }

    // MARK: following a swipe

    /// The space's header and list, which a two-finger swipe moves sideways. Their layers move, not their frames: a
    /// layout of the sidebar on every scroll event (on the main thread, which the engine shares) made the swipe lag.
    private var swipeLayers: [CALayer] { ([header, scroll] as [NSView]).compactMap(\.layer) }

    /// Puts the header and list `offset` points to the side, fading as they go, at once.
    func followSwipe(_ offset: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in swipeLayers {
            layer.removeAnimation(forKey: "swipe")
            place(layer, at: offset)
        }
        CATransaction.commit()
    }

    /// Eases the header and list from where they are to `offset`: back to rest, or out of view before the next space.
    func settleSwipe(at offset: CGFloat, duration: TimeInterval, then done: (() -> Void)? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(done)
        for layer in swipeLayers {
            let shown = layer.presentation() ?? layer
            let move = CABasicAnimation(keyPath: "transform")
            move.fromValue = NSValue(caTransform3D: shown.transform)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = shown.opacity
            place(layer, at: offset)
            move.toValue = NSValue(caTransform3D: layer.transform)
            fade.toValue = layer.opacity
            let group = CAAnimationGroup()
            group.animations = [move, fade]
            group.duration = duration
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            layer.add(group, forKey: "swipe")
        }
        CATransaction.commit()
    }

    /// The next space's header and list come in from `offset`, the side the last ones left from, to rest.
    func swipeIn(from offset: CGFloat, duration: TimeInterval) {
        followSwipe(offset)
        settleSwipe(at: 0, duration: duration)
    }

    private func place(_ layer: CALayer, at offset: CGFloat) {
        layer.setAffineTransform(offset == 0 ? .identity : CGAffineTransform(translationX: offset, y: 0))
        layer.opacity = Float(1 - min(0.6, abs(offset) / max(bounds.width, 1)))
    }

    /// A downloaded update waiting for a restart, offered above the space bar; nil hides it.
    func showUpdate(_ version: String?) {
        guard version != updateVersion else { return }
        updateVersion = version
        updateBanner.isHidden = version == nil
        if let version { updateBanner.show(version: version) }
        needsLayout = true
    }


    /// The list, the header and the space bar, for the current space; `direction` slides the list in from the side
    /// the new space sits on.
    func reload(direction: Int = 0) {
        list.reload(direction: direction)
        header.show(space)
        rebuildSpaces()
    }

    func reloadItem(_ item: SidebarItem) { list.reloadItem(item) }
    func reflectSelection() { list.reflectSelection() }
    func reveal(_ item: SidebarItem) { list.reveal(item) }
    func rename(_ item: SidebarItem, selectAll: Bool = false) { list.rename(item, selectAll: selectAll) }
    func toggleFolder(_ folder: SidebarItem) { list.toggleFolder(folder) }
    /// In the middle of something (a rename, its menu): slid out over the page, the sidebar stays out until it's done.
    var isBusy: Bool { list.isBusy }

    func updateAddress(_ tab: ArdiaCoreTab?) {
        address.show(url: tab?.url)
        backButton.isEnabled = tab?.canGoBack ?? false
        forwardButton.isEnabled = tab?.canGoForward ?? false
        reloadButton.isEnabled = tab != nil
    }

    // MARK: spaces

    /// Space buttons sit between the extensions and new-space buttons. When their icons don't fit they shrink to
    /// dots, as in Arc; when the dots don't fit either, the strip scrolls sideways and keeps the current one in view.
    private func layoutSpaces(barY: CGFloat) {
        let left: CGFloat = downloadsButton.isHidden ? 48 : 78
        let room = NSRect(x: left, y: barY, width: max(0, bounds.width - left - 48), height: 28)
        let buttons = spaceStack.arrangedSubviews.compactMap { $0 as? SpaceButton }
        let gaps = CGFloat(max(0, buttons.count - 1)) * spaceStack.spacing
        let compact = CGFloat(buttons.count) * SpaceButton.fullWidth + gaps > room.width
        buttons.forEach { $0.compact = compact }
        let natural = CGFloat(buttons.count) * (compact ? SpaceButton.compactWidth : SpaceButton.fullWidth) + gaps
        let fits = natural <= room.width
        spaceStrip.frame = fits ? NSRect(x: max(left, (bounds.width - natural) / 2), y: barY, width: natural, height: 28) : room
        spaceStack.frame = NSRect(x: 0, y: 0, width: natural, height: 28)
        if !fits, let current = buttons.first(where: \.current) {
            spaceStack.layoutSubtreeIfNeeded()
            current.scrollToVisible(current.bounds.insetBy(dx: -24, dy: 0))
        }
    }

    private func rebuildSpaces() {
        spaceStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for target in store.state.spaces {
            let button = SpaceButton(space: target, current: target === space)
            button.onClick = { [weak self] in self?.delegate?.sidebarSwitch(to: target) }
            button.dropTarget = { [weak self] info in
                guard let self, target !== space, let item = list.draggedItem(info) else { return false }
                delegate?.sidebarMove(item, to: target)
                return true
            }
            button.menu = spaceMenu(for: target, anchor: button)
            spaceStack.addArrangedSubview(button)
        }
        needsLayout = true
    }

    /// The space menu, Arc-style. Opened from the space header, a space button or, with the tab items,
    /// from empty sidebar space.
    private func spaceMenu(for target: Space, anchor: NSView, withTabItems: Bool = false) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let isCurrent = target === space
        menu.addItem(ClosureMenuItem(L("space.changeIcon")) { [weak self] in
            guard let self else { return }
            let picker = IconPicker(selected: target.symbol, tint: NSColor(hex: target.colorHex)) { [weak self] symbol in
                self?.delegate?.sidebarRestyle(target, color: nil, symbol: symbol)
            }
            let from = isCurrent ? header : anchor
            picker.present(relativeTo: from.bounds, of: from, edge: .maxX)
        })
        menu.addItem(ClosureMenuItem(L("space.rename")) { [weak self] in self?.delegate?.sidebarRename(target) })
        menu.addItem(ClosureMenuItem(L("space.editTheme")) { [weak self] in
            guard let self else { return }
            delegate?.sidebarEditTheme(target, from: isCurrent ? header : anchor)
        })

        if withTabItems {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(L("sidebar.newTab")) { [weak self] in self?.delegate?.sidebarNewTab() })
            menu.addItem(ClosureMenuItem(L("sidebar.newFolder")) { [weak self] in self?.delegate?.sidebarNewFolder() })
            let closed = delegate?.sidebarClosedCount() ?? 0
            if closed > 0 {
                menu.addItem(ClosureMenuItem(L("tabs.reopenClosed")) { [weak self] in self?.delegate?.sidebarReopenClosed() })
            }
            let clearable = delegate?.sidebarClearableCount() ?? 0
            if clearable > 0 {
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem(L("today.clear.menu", clearable)) { [weak self] in self?.delegate?.sidebarClearToday() })
            }
        }

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("space.manage")) { [weak self] in self?.delegate?.sidebarManageSpaces() })
        let delete = ClosureMenuItem(L("space.delete")) { [weak self] in self?.delegate?.sidebarDelete(target) }
        delete.isEnabled = store.state.spaces.count > 1
        menu.addItem(delete)
        return menu
    }

    @objc private func addSpaceTapped() { delegate?.sidebarNewSpace() }
    @objc private func extensionsTapped() { delegate?.sidebarExtensions(from: extensionsButton) }
    @objc private func downloadsTapped() { delegate?.sidebarDownloads(from: downloadsButton) }

    /// The downloads button: shown once there's a download, with a ring while any is running.
    func showDownloads(visible: Bool, progress: Double?, unseen: Bool) {
        downloadsButton.progress = progress
        downloadsButton.unseen = unseen
        guard downloadsButton.isHidden == visible else { return }
        downloadsButton.isHidden = !visible
        needsLayout = true
    }
    @objc private func toggleTapped() { delegate?.sidebarToggle() }
    @objc private func backTapped() { delegate?.sidebarBack() }
    @objc private func forwardTapped() { delegate?.sidebarForward() }
    @objc private func reloadTapped() { delegate?.sidebarReload() }
}

// MARK: - the floating card

private final class CardBackground: NSVisualEffectView, WindowDragSurface {}

/// See `slideClip`. It never takes a press itself: one on empty space goes on to the sidebar, which drags the window.
private final class SlideClip: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
private final class CardTint: NSView, WindowDragSurface {}

#if DRIFT_DEV
extension SidebarView {
    var debugOutline: NSOutlineView { outline }
    var debugCurrentSpace: Space { space }

    var debugEmptySpaceMenu: [String] {
        let menu = NSMenu()
        list.menuNeedsUpdate(menu)
        return menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    var debugClearShown: String {
        let row = outline.row(forItem: SidebarMarker.divider)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? DividerCell else { return "-" }
        return cell.showsClear ? "shown (\(cell.clearTip ?? ""))" : "hidden"
    }

    func debugCloseTip(for item: SidebarItem) -> String {
        let row = outline.row(forItem: item)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCell else { return "-" }
        return cell.debugCloseTip
    }

    func debugDescribe(_ c: Container, _ i: Int) -> String {
        switch c {
        case .pinned: return "pinned[\(i)]"
        case .today: return "today[\(i)]"
        case let .folder(f): return "folder \(f.title)[\(i)]"
        }
    }

    /// The drop target for a pointer at `fraction` down `item`'s row, or below every row when `item` is nil.
    func debugDrop(_ moving: SidebarItem, over item: AnyObject?, fraction: CGFloat) -> String {
        let point: NSPoint
        if let item {
            let row = outline.row(forItem: item)
            let rect = outline.rect(ofRow: row)
            point = outline.convert(NSPoint(x: rect.midX, y: rect.minY + rect.height * fraction), to: nil)
        } else {
            let last = outline.rect(ofRow: outline.numberOfRows - 1)
            point = outline.convert(NSPoint(x: last.midX, y: last.maxY + 60), to: nil)
        }
        guard let t = SidebarDrop(outline: outline, space: space).target(at: point, moving: moving) else { return "none" }
        return debugDescribe(t.container, t.index)
    }

    var debugOutlineFillsHeight: Bool { outline.frame.height >= scroll.contentSize.height - 1 }

    func debugFastClicks(on item: SidebarItem, count: Int) {
        let row = outline.row(forItem: item)
        guard row >= 0, let window else { return }
        let rect = outline.rect(ofRow: row)
        let point = outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        for n in 1...count {
            let make = { (type: NSEvent.EventType) in
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: n, pressure: 1)!
            }
            NSApp.postEvent(make(.leftMouseUp), atStart: false)
            NSApp.sendEvent(make(.leftMouseDown))
        }
    }

    /// A real click through NSApp.sendEvent: the mouse-up is queued first so the table's tracking loop ends.
    func debugClickRow(of item: SidebarItem) {
        let row = outline.row(forItem: item)
        guard row >= 0, let window else { return }
        let rect = outline.rect(ofRow: row)
        let point = outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        Trace.log("debug click at row \(row): \(WindowDrag.probe(point, in: window)), key=\(window.isKeyWindow), visible=\(outline.visibleRect.intersects(rect))")
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        NSApp.postEvent(up, atStart: false)
        NSApp.sendEvent(down)
    }

    /// Keys as they reach the sidebar once it holds focus (after a click on it, or a rename that lost focus).
    func debugKey(characters: String, keyCode: UInt16) {
        guard let window else { return }
        let chars = keyCode == 126 ? String(UnicodeScalar(NSUpArrowFunctionKey)!) : keyCode == 125 ? String(UnicodeScalar(NSDownArrowFunctionKey)!) : characters
        guard let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: keyCode >= 123 ? [.numericPad, .function] : [],
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                         context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                         isARepeat: false, keyCode: keyCode) else { return }
        if window.makeFirstResponder(outline) { window.firstResponder?.keyDown(with: key) } else { outline.keyDown(with: key) }
    }

    func debugCommitRename(_ title: String) -> Bool { list.debugCommitRename(title) }
}
#endif
