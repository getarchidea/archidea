import AppKit

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
}

final class SidebarMarker {
    enum Kind { case divider, newTab }
    let kind: Kind
    private init(_ kind: Kind) { self.kind = kind }
    static let divider = SidebarMarker(.divider)
    static let newTab = SidebarMarker(.newTab)
}

final class SidebarView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate, WindowDragSurface {
    static let itemType = NSPasteboard.PasteboardType("dev.drift.sidebar-item")

    weak var delegate: SidebarViewDelegate?
    private let store: Store
    private var space: Space { store.state.currentSpace }

    private let card = CardBackground()
    private let cardTint = CardTint()
    private let toggleButton = ChromeButton(symbol: "sidebar.left", tip: L("sidebar.toggle.tip"))
    private let backButton = ChromeButton(symbol: "arrow.left", tip: L("sidebar.back.tip"))
    private let forwardButton = ChromeButton(symbol: "arrow.right", tip: L("sidebar.forward.tip"))
    private let reloadButton = ChromeButton(symbol: "arrow.clockwise", tip: L("sidebar.reload.tip"))
    private let address = AddressPill()
    private let header = SpaceHeader()
    private let scroll = ThinScrollView()
    private let outline = SidebarOutline()
    private let extensionsButton = ChromeButton(symbol: "puzzlepiece.extension", tip: L("sidebar.extensions.tip"))
    private let addSpaceButton = ChromeButton(symbol: "plus", tip: L("sidebar.newSpace.tip"))
    /// Next to the extensions button once there's something downloaded or downloading.
    let downloadsButton = DownloadsButton()
    private let spaceStack = NSStackView()
    private let updateBanner = UpdateBanner()
    private var updateVersion: String?
    /// Holds the space buttons; scrolls sideways once even their compact dots don't fit.
    private let spaceStrip = SpaceStrip()
    private var reflecting = false
    private var renaming: SidebarItem?
    private weak var renameLabel: NSTextField?

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

    init(store: Store) {
        self.store = store
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
            guard let self, let item = draggedItem(info) else { return false }
            return move(item, to: .pinned, at: 0)
        }
        header.onClick = { [weak self] in
            guard let self else { return }
            spaceMenu(for: space, anchor: header).popUp(positioning: nil, at: NSPoint(x: 0, y: header.bounds.height + 2), in: header)
        }
        addSubview(header)

        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.rowHeight = 36
        outline.intercellSpacing = NSSize(width: 0, height: 4)
        outline.indentationPerLevel = 16
        // By default the outline column widens by a level's indent when a folder first opens, which pushed rows past
        // the sidebar's edge until the next resize. Rows keep the sidebar's width; cells indent inside it.
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.focusRingType = .none
        outline.allowsTypeSelect = false
        outline.allowsEmptySelection = true
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.doubleAction = #selector(rowDoubleClicked)
        outline.onMiddleClick = { [weak self] row in self?.middleClicked(row) }
        outline.registerForDraggedTypes([Self.itemType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        // The drop indicator is our own (DropIndicator): rows sliding apart made the gap on screen and the rows
        // under the pointer drift apart, and AppKit's line barely shows which group a drop goes into.
        outline.draggingDestinationFeedbackStyle = .none
        outline.onDragFinished = { [weak self] in self?.dropIndicator.hide() }
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.fadesEdges = true
        addSubview(scroll)

        spaceStack.orientation = .horizontal
        spaceStack.spacing = 2
        spaceStrip.documentView = spaceStack
        addSubview(spaceStrip)
        updateBanner.isHidden = true
        addSubview(updateBanner)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(expansionChanged), name: NSOutlineView.itemDidExpandNotification, object: outline)
        center.addObserver(self, selector: #selector(expansionChanged), name: NSOutlineView.itemDidCollapseNotification, object: outline)
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
        header.frame = NSRect(x: 12 + swipeOffset, y: top + 48, width: width - 24, height: 28)
        let listTop = top + 80
        let banner: CGFloat = updateVersion == nil ? 0 : 58
        scroll.frame = NSRect(x: swipeOffset, y: listTop, width: width, height: max(0, height - listTop - 48 - banner))
        let fade = 1 - min(0.6, abs(swipeOffset) / max(width, 1))
        header.alphaValue = fade
        scroll.alphaValue = fade
        updateBanner.frame = NSRect(x: 10, y: height - 48 - banner + 4, width: width - 20, height: max(0, banner - 8))
        if let column = outline.tableColumns.first, abs(column.width - scroll.contentSize.width) > 0.5 {
            column.width = scroll.contentSize.width
        }
        if let item = pendingReveal, scroll.contentSize.height >= outline.rowHeight * 3 {
            pendingReveal = nil
            DispatchQueue.main.async { [weak self] in self?.reveal(item) }
        }

        let barY = height - 40
        extensionsButton.frame = NSRect(x: 12, y: barY, width: 28, height: 28)
        downloadsButton.frame = NSRect(x: 42, y: barY, width: 28, height: 28)
        addSpaceButton.frame = NSRect(x: width - 40, y: barY, width: 28, height: 28)
        layoutSpaces(barY: barY)
    }

    // MARK: public

    var addressAnchor: NSView { address }

    /// How far the space's header and list follow a two-finger swipe across the sidebar.
    var swipeOffset: CGFloat = 0 {
        didSet {
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }

    /// Eases the list to `offset` (back to rest, or out of view before the next space comes in).
    func settleSwipe(at offset: CGFloat, duration: TimeInterval, then done: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            context.allowsImplicitAnimation = true
            swipeOffset = offset
        }, completionHandler: done)
    }

    /// A downloaded update waiting for a restart, offered above the space bar; nil hides it.
    func showUpdate(_ version: String?) {
        guard version != updateVersion else { return }
        updateVersion = version
        updateBanner.isHidden = version == nil
        if let version { updateBanner.show(version: version) }
        needsLayout = true
    }

    /// `direction` slides the list in from the side the new space sits on.
    func reload(direction: Int = 0) {
        endRename(commit: true)
        if direction != 0, let layer = scroll.layer {
            let transition = CATransition()
            transition.type = .push
            transition.subtype = direction > 0 ? .fromRight : .fromLeft
            transition.duration = 0.22
            transition.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            layer.add(transition, forKey: "space")
        }
        outline.reloadData()
        func restore(_ items: [SidebarItem]) {
            for item in items where item.isFolder {
                if item.expanded { outline.expandItem(item) } else { outline.collapseItem(item) }
                restore(item.children)
            }
        }
        reflecting = true
        restore(space.pinned)
        reflecting = false
        header.show(space)
        rebuildSpaces()
        reflectSelection()
    }

    func reloadItem(_ item: SidebarItem) {
        guard item !== renaming, outline.row(forItem: item) >= 0 else { return }
        outline.reloadItem(item, reloadChildren: false)
        if let id = space.selectedID, id == item.id { reflectSelection() }
    }

    /// The active tab is the model's (`space.selectedID`) and nothing else: the table's own selection is never used,
    /// so nothing AppKit does with rows (type-select, arrows, reloads, expanding) can switch tabs.
    func reflectSelection() {
        let active = space.selectedID.flatMap { space.find($0) }
        outline.enumerateAvailableRowViews { rowView, row in
            (rowView as? SidebarRowView)?.isActive = active != nil && outline.item(atRow: row) as AnyObject === active
        }
    }

    /// Opens the folders around a tab the user just switched to and scrolls it into view.
    func reveal(_ item: SidebarItem) {
        var parent = space.location(of: item)?.parent
        while let folder = parent {
            if !outline.isItemExpanded(folder) { outline.animator().expandItem(folder) }
            parent = space.location(of: folder)?.parent
        }
        // Before the window has its size the list is a few points tall, and scrolling a row "into view" there
        // left the list scrolled past the pins once it grew. The row is brought into view after layout instead.
        if scroll.contentSize.height < outline.rowHeight * 3 {
            pendingReveal = item
        } else {
            let row = outline.row(forItem: item)
            if row >= 0 { outline.scrollRowToVisible(row) }
        }
        reflectSelection()
    }

    private var pendingReveal: SidebarItem?

    func updateAddress(_ tab: ArdiaCoreTab?) {
        address.show(url: tab?.url)
        backButton.isEnabled = tab?.canGoBack ?? false
        forwardButton.isEnabled = tab?.canGoForward ?? false
        reloadButton.isEnabled = tab != nil
    }

    /// The row's own label becomes editable, so the name stays exactly where it was drawn.
    /// Return or clicking away keeps it, Escape drops it.
    func rename(_ item: SidebarItem, selectAll: Bool = false) {
        endRename(commit: true)
        let row = outline.row(forItem: item)
        guard row >= 0 else { return }
        outline.scrollRowToVisible(row)
        guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCell else { return }
        let label = cell.beginEditing(item.isFolder ? item.title : item.displayTitle)
        label.delegate = self
        renaming = item
        renameLabel = label
        window?.makeFirstResponder(label)
        if let editor = label.currentEditor() as? NSTextView {
            editor.drawsBackground = false
            editor.backgroundColor = .clear
            editor.insertionPointColor = .labelColor
            let length = label.stringValue.utf16.count
            editor.selectedRange = selectAll ? NSRange(location: 0, length: length) : NSRange(location: length, length: 0)
        }
    }

    private func endRename(commit: Bool) {
        guard let item = renaming else { return }
        let label = renameLabel
        renaming = nil
        renameLabel = nil
        let title = label?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if commit {
            if item.isFolder {
                if !title.isEmpty { item.title = title }
            } else {
                // Emptied, or set back to the page's own title: the tab follows the page again.
                item.customTitle = title.isEmpty || title == item.title ? nil : title
            }
        }
        if let label, window?.firstResponder === label.currentEditor() { window?.makeFirstResponder(nil) }
        (label?.superview as? SidebarCell)?.endEditing()
        outline.reloadItem(item, reloadChildren: false)
        delegate?.sidebarChanged()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === renameLabel else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): endRename(commit: true)
        case #selector(NSResponder.cancelOperation(_:)): endRename(commit: false)
        default: return false
        }
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if let label = renameLabel, obj.object as? NSObject === label { endRename(commit: true) }
    }

    func pickIcon(for item: SidebarItem) {
        let row = outline.row(forItem: item)
        guard row >= 0 else { return }
        let picker = IconPicker(symbols: SpaceStyle.folderSymbols, selected: item.icon ?? "folder",
                                tint: NSColor(hex: space.colorHex)) { [weak self] symbol in
            item.icon = symbol == "folder" ? nil : symbol
            self?.outline.reloadItem(item, reloadChildren: false)
            self?.delegate?.sidebarChanged()
        }
        picker.present(relativeTo: outline.rect(ofRow: row).insetBy(dx: 10, dy: 0), of: outline, edge: .maxX)
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
                guard let self, target !== space, let item = draggedItem(info) else { return false }
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
            let picker = IconPicker(symbols: SpaceStyle.symbols, selected: target.symbol, tint: NSColor(hex: target.colorHex)) { [weak self] symbol in
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

    // MARK: clicks

    @objc private func rowClicked() {
        let row = outline.clickedRow
        Trace.log("sidebar click row=\(row)")
        guard row >= 0 else { return }
        switch outline.item(atRow: row) {
        case let marker as SidebarMarker where marker.kind == .newTab:
            delegate?.sidebarNewTab()
        case let item as SidebarItem where item.isFolder:
            toggleFolder(item)
        case let item as SidebarItem:
            delegate?.sidebarSelect(item, cause: "sidebar-click")
        default:
            break
        }
    }

    @objc private func rowDoubleClicked() {
        let row = outline.clickedRow
        guard row >= 0, let item = outline.item(atRow: row) as? SidebarItem else { return }
        // The table reports the second click of a quick series here instead of as a click: a folder still toggles on it.
        if item.isFolder { toggleFolder(item) } else { rename(item) }
    }

    func toggleFolder(_ folder: SidebarItem) {
        if outline.isItemExpanded(folder) { outline.animator().collapseItem(folder) } else { outline.animator().expandItem(folder) }
    }

    private func middleClicked(_ row: Int) {
        guard let item = outline.item(atRow: row) as? SidebarItem, !item.isFolder else { return }
        delegate?.sidebarClose(item)
    }

    @objc private func expansionChanged(_ note: Notification) {
        guard !reflecting, let item = note.userInfo?["NSObject"] as? SidebarItem else { return }
        item.expanded = note.name == NSOutlineView.itemDidExpandNotification
        // Reloading the folder's row while AppKit animates its children in or out left stale row positions
        // (gaps, overlapping rows) until the next layout. Only its icon changes, so only that is updated.
        let row = outline.row(forItem: item)
        if row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell {
            cell.setFolderOpen(item.expanded, icon: item.icon)
        }
        delegate?.sidebarChanged()
    }

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? SidebarItem else { return space.pinned.count + 2 + space.today.count }
        return item.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let item = item as? SidebarItem { return item.children[index] }
        let pinned = space.pinned.count
        if index < pinned { return space.pinned[index] }
        if index == pinned { return SidebarMarker.divider }
        if index == pinned + 1 { return SidebarMarker.newTab }
        return space.today[index - pinned - 2]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarItem)?.isFolder ?? false
    }

    // MARK: NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? SidebarMarker)?.kind == .divider ? 20 : 36
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = SidebarRowView()
        row.hoverable = !((item as? SidebarMarker)?.kind == .divider)
        row.isActive = (item as? SidebarItem).map { $0.id == space.selectedID } ?? false
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let marker = item as? SidebarMarker {
            if marker.kind == .newTab { return NewTabCell() }
            let divider = DividerCell()
            let clearable = delegate?.sidebarClearableCount() ?? 0
            divider.showsClear = space.today.count >= 3 && clearable > 0
            divider.clearTip = L("today.clear.tip", clearable)
            divider.onClear = { [weak self] in self?.delegate?.sidebarClearToday() }
            return divider
        }
        guard let item = item as? SidebarItem else { return nil }
        let cell = (outlineView.makeView(withIdentifier: SidebarCell.identifier, owner: nil) as? SidebarCell) ?? SidebarCell()
        let pinned = space.isPinned(item)
        let loaded = delegate?.sidebarIsLoaded(item) ?? false
        cell.configure(item: item,
                       icon: item.isFolder ? nil : delegate?.sidebarFavicon(for: item),
                       loaded: item.isFolder || !pinned || loaded,
                       loading: delegate?.sidebarIsLoading(item) ?? false,
                       closable: !item.isFolder,
                       tint: NSColor(hex: space.colorHex))
        cell.setCloseStyle(pinned: pinned, loaded: loaded)
        cell.onClose = { [weak self] in self?.delegate?.sidebarClose(item) }
        return cell
    }

    // MARK: drag and drop

    /// Where a drop goes: the model's own lists, whose rules (`Space.place`) the sidebar doesn't repeat.
    typealias Container = Space.Slot

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let item = item as? SidebarItem else { return nil }
        let writer = NSPasteboardItem()
        writer.setString(item.id.uuidString, forType: Self.itemType)
        return writer
    }

    func draggedItem(_ info: NSDraggingInfo) -> SidebarItem? {
        guard let string = info.draggingPasteboard.string(forType: Self.itemType), let id = UUID(uuidString: string) else { return nil }
        return space.find(id)
    }

    private func container(of item: SidebarItem) -> Container? { space.slot(of: item) }

    struct DropTarget {
        let container: Container
        let index: Int
        /// Into a folder as a whole (it lights up), not at a line between rows.
        var onto = false
    }

    /// Where a drop lands, from the pointer's height alone. AppKit's own proposal also reads how far right the
    /// pointer is to pick a nesting level, so with the pointer mid-row a group fell into the group above, nothing
    /// could go above the top group, and a tab let go below the list went to the top of the pins.
    /// - a tab's upper half drops before it, its lower half after it (the last child of a folder stays inside);
    /// - a folder's top quarter drops before it, its bottom quarter after it (or first inside it when open),
    ///   the middle drops into it;
    /// - the divider's upper half ends the pins, everything below it is Today; empty space below the list is the
    ///   end of Today, above the first row the start of the pins.
    private func dropTarget(at pointInWindow: NSPoint, moving: SidebarItem) -> DropTarget? {
        let point = outline.convert(pointInWindow, from: nil)
        let row = outline.row(at: point)
        var target: DropTarget
        if row < 0 {
            let first = outline.numberOfRows > 0 ? outline.rect(ofRow: 0) : .zero
            target = point.y < first.minY ? DropTarget(container: .pinned, index: 0) : DropTarget(container: .today, index: space.today.count)
        } else {
            let rect = outline.rect(ofRow: row)
            let fraction = (point.y - rect.minY) / max(rect.height, 1)
            switch outline.item(atRow: row) {
            case let marker as SidebarMarker:
                target = marker.kind == .divider && fraction < 0.5
                    ? DropTarget(container: .pinned, index: space.pinned.count) : DropTarget(container: .today, index: 0)
            case let folder as SidebarItem where folder.isFolder:
                guard let around = container(of: folder), let index = space.location(of: folder)?.index else { return nil }
                let open = outline.isItemExpanded(folder) && !folder.children.isEmpty
                if fraction < 0.25 {
                    target = DropTarget(container: around, index: index)
                } else if fraction > 0.75 {
                    target = open ? DropTarget(container: .folder(folder), index: 0) : DropTarget(container: around, index: index + 1)
                } else {
                    target = DropTarget(container: .folder(folder), index: folder.children.count, onto: true)
                }
            case let item as SidebarItem:
                guard let around = container(of: item), let index = space.location(of: item)?.index else { return nil }
                target = DropTarget(container: around, index: fraction < 0.5 ? index : index + 1)
            default:
                return nil
            }
        }
        // Folders live among the pins; one let go in Today joins the end of the pins.
        if moving.isFolder, case .today = target.container { target = DropTarget(container: .pinned, index: space.pinned.count) }
        if case let .folder(folder) = target.container, space.contains(moving, descendant: folder) { return nil }
        return target
    }

    /// The outline's own (parent, child index) for a model position, so AppKit draws the line in the right place.
    private func outlinePosition(_ container: Container, _ index: Int) -> (SidebarItem?, Int) {
        switch container {
        case .pinned: return (nil, index)
        case .today: return (nil, space.pinned.count + 2 + index)
        case let .folder(folder): return (folder, index)
        }
    }

    private var pendingDrop: DropTarget?
    private let dropIndicator = DropIndicator()

    /// The last row showing `item` or anything inside it.
    private func lastRow(of item: SidebarItem) -> Int {
        var row = outline.row(forItem: item)
        if item.isFolder, outline.isItemExpanded(item), let last = item.children.last { row = max(row, lastRow(of: last)) }
        return row
    }

    /// The drop line: its height between rows and how far it's indented, in the outline's coordinates.
    private func indicatorLine(for target: DropTarget) -> (y: CGFloat, level: Int)? {
        guard !target.onto else { return nil }
        let items: [SidebarItem]
        let level: Int
        switch target.container {
        case .pinned: (items, level) = (space.pinned, 0)
        case .today: (items, level) = (space.today, 0)
        case let .folder(folder): (items, level) = (folder.children, outline.level(forItem: folder) + 1)
        }
        let y: CGFloat
        if target.index < items.count {
            y = outline.rect(ofRow: outline.row(forItem: items[target.index])).minY
        } else if let last = items.last {
            // The end of a group sits just inside its frame rather than on the frame's edge.
            y = outline.rect(ofRow: lastRow(of: last)).maxY - (level > 0 ? 5 : 0)
        } else if case let .folder(folder) = target.container {
            y = outline.rect(ofRow: outline.row(forItem: folder)).maxY
        } else if case .pinned = target.container {
            y = outline.rect(ofRow: outline.row(forItem: SidebarMarker.divider)).minY
        } else {
            y = outline.rect(ofRow: outline.row(forItem: SidebarMarker.newTab)).maxY
        }
        return (y, min(level, 3))
    }

    /// The group a drop goes into, from its folder's row to its last row, so "into this group" is plain to see.
    private func indicatorGroup(for target: DropTarget) -> NSRect? {
        guard case let .folder(folder) = target.container else { return nil }
        let first = outline.row(forItem: folder)
        guard first >= 0 else { return nil }
        let top = outline.rect(ofRow: first)
        let bottom = outline.rect(ofRow: lastRow(of: folder))
        let indent = CGFloat(min(outline.level(forItem: folder), 3)) * outline.indentationPerLevel
        return NSRect(x: indent + 6, y: top.minY + 1, width: outline.bounds.width - indent - 12, height: bottom.maxY - top.minY - 2)
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard let moving = draggedItem(info), let target = dropTarget(at: info.draggingLocation, moving: moving) else {
            pendingDrop = nil
            dropIndicator.hide()
            return []
        }
        pendingDrop = target
        dropIndicator.show(line: indicatorLine(for: target), group: indicatorGroup(for: target), onto: target.onto, in: outline)
        if target.onto, case let .folder(folder) = target.container {
            outlineView.setDropItem(folder, dropChildIndex: NSOutlineViewDropOnItemIndex)
        } else {
            let (parent, child) = outlinePosition(target.container, target.index)
            outlineView.setDropItem(parent, dropChildIndex: child)
        }
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        defer { pendingDrop = nil }
        guard let moving = draggedItem(info), let target = pendingDrop ?? dropTarget(at: info.draggingLocation, moving: moving) else {
            return false
        }
        return move(moving, to: target.container, at: target.index)
    }

    /// A folder being dragged folds up, so its tabs don't trail along under the pointer; it opens again after.
    private var foldedForDrag: SidebarItem?

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                     forItems draggedItems: [Any]) {
        guard let folder = draggedItems.first as? SidebarItem, folder.isFolder, outlineView.isItemExpanded(folder) else { return }
        foldedForDrag = folder
        outlineView.collapseItem(folder)
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                     operation: NSDragOperation) {
        guard let folder = foldedForDrag else { return }
        foldedForDrag = nil
        if outlineView.row(forItem: folder) >= 0 { outlineView.expandItem(folder) }
    }

    /// The one place a sidebar item changes position within the space; what a list may hold is the model's business
    /// (`Space.move`): pins and folders give a tab a home URL, Today takes it away, folders stay among the pins.
    @discardableResult
    func move(_ moving: SidebarItem, to container: Container, at index: Int) -> Bool {
        guard space.location(of: moving) != nil else { return false }
        if case let .folder(folder) = container, space.contains(moving, descendant: folder) { return false }
        space.move(moving, to: container, at: index)
        reload()
        delegate?.sidebarChanged()
        return true
    }

    // MARK: context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.contextRow
        let clicked = row >= 0 ? outline.item(atRow: row) as? SidebarItem : nil
        guard let item = clicked else {
            let full = spaceMenu(for: space, anchor: header, withTabItems: true)
            for entry in full.items {
                full.removeItem(entry)
                menu.addItem(entry)
            }
            return
        }
        if item.isFolder {
            menu.addItem(ClosureMenuItem(L("item.rename")) { [weak self] in DispatchQueue.main.async { self?.rename(item) } })
            menu.addItem(ClosureMenuItem(L("folder.icon")) { [weak self] in self?.pickIcon(for: item) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(L("folder.delete")) { [weak self] in self?.delegate?.sidebarDeleteFolder(item) })
            return
        }
        let pinned = space.isPinned(item)
        menu.addItem(ClosureMenuItem(pinned ? L("tab.unpin") : L("tab.pin")) { [weak self] in self?.delegate?.sidebarTogglePin(item) })
        if pinned, let home = item.pinnedURL, home != item.url {
            menu.addItem(ClosureMenuItem(L("tab.resetPin")) { [weak self] in self?.delegate?.sidebarResetPin(item) })
        }
        menu.addItem(ClosureMenuItem(L("item.rename")) { [weak self] in DispatchQueue.main.async { self?.rename(item) } })
        if item.customTitle != nil {
            menu.addItem(ClosureMenuItem(L("tab.resetName")) { [weak self] in
                item.customTitle = nil
                self?.outline.reloadItem(item, reloadChildren: false)
                self?.delegate?.sidebarChanged()
            })
        }
        menu.addItem(ClosureMenuItem(L("tab.copyLink")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.url, forType: .string)
        })
        let others = store.state.spaces.filter { $0 !== space }
        if !others.isEmpty {
            let move = NSMenuItem(title: L("tab.moveToSpace"), action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for target in others {
                let entry = ClosureMenuItem(target.name) { [weak self] in self?.delegate?.sidebarMove(item, to: target) }
                entry.image = NSImage(systemSymbolName: target.symbol, accessibilityDescription: nil)
                sub.addItem(entry)
            }
            move.submenu = sub
            menu.addItem(move)
        }
        menu.addItem(.separator())
        if pinned {
            if delegate?.sidebarIsLoaded(item) ?? false {
                menu.addItem(ClosureMenuItem(L("tab.unload")) { [weak self] in self?.delegate?.sidebarClose(item) })
            }
            menu.addItem(ClosureMenuItem(L("tab.removePinned")) { [weak self] in self?.delegate?.sidebarRemove(item) })
        } else {
            menu.addItem(ClosureMenuItem(L("tab.close")) { [weak self] in self?.delegate?.sidebarClose(item) })
        }
    }

}

// MARK: - the floating card

private final class CardBackground: NSVisualEffectView, WindowDragSurface {}
private final class CardTint: NSView, WindowDragSurface {}

#if DRIFT_DEV
extension SidebarView {
    var debugOutline: NSOutlineView { outline }
    var debugCurrentSpace: Space { space }

    var debugEmptySpaceMenu: [String] {
        let menu = NSMenu()
        menuNeedsUpdate(menu)
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
        guard let t = dropTarget(at: point, moving: moving) else { return "none" }
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

    func debugCommitRename(_ title: String) -> Bool {
        guard let field = renameLabel, window?.firstResponder === field.currentEditor() else { return false }
        field.stringValue = title
        endRename(commit: true)
        return true
    }
}
#endif
