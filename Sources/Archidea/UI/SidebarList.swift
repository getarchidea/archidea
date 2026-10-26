import AppKit
import ArchideaCore

/// The sidebar's list: the current space's pins, the divider and new-tab row, and Today, in an outline. It shows the
/// model, and changes it the way the person asks: clicks, renames, drags and its menu. The sidebar around it is the
/// chrome (toolbar, address, space bar) and lays it out.
final class SidebarList: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    static let itemType = NSPasteboard.PasteboardType("dev.drift.sidebar-item")

    weak var delegate: SidebarViewDelegate?
    /// The menu for the list's empty space: the space's own, which the sidebar builds.
    var emptyAreaMenu: (() -> NSMenu)?
    /// A row's drag began (true) or ended: the favourites make room to take it.
    var onDrag: ((Bool) -> Void)?
    /// An item moved by a drop (onto the list, the header): it may have left the favourites, which show it again.
    var onMove: (() -> Void)?

    let outline = SidebarOutline()
    let scroll = SidebarScroll()

    private let store: Store
    /// The window's own view of the sidebar: which space it lists, which tab is in front.
    private let windowState: WindowState
    private var space: Space { store.state.space(shownIn: windowState) }
    private var selectedID: UUID? { windowState.selectedID(in: space) }
    private var reflecting = false
    private var renaming: SidebarItem?
    private weak var renameLabel: NSTextField?
    private var pendingReveal: SidebarItem?
    private var menuOpen = false
    private var pendingDrop: SidebarDrop.Target?
    private let dropIndicator = DropIndicator()
    /// A folder being dragged folds up, so its tabs don't trail along under the pointer; it opens again after.
    private var foldedForDrag: SidebarItem?
    private var drop: SidebarDrop { SidebarDrop(outline: outline, space: space) }

    init(store: Store, window windowState: WindowState) {
        self.store = store
        self.windowState = windowState
        super.init()
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

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(expansionChanged), name: NSOutlineView.itemDidExpandNotification, object: outline)
        center.addObserver(self, selector: #selector(expansionChanged), name: NSOutlineView.itemDidCollapseNotification, object: outline)
    }

    /// In the middle of something (a rename, its menu): slid out over the page, the sidebar stays out until it's done.
    var isBusy: Bool { renaming != nil || menuOpen }

    /// After the sidebar's layout: rows keep its width, and a tab waiting to be revealed is, once the list is tall
    /// enough to scroll it into view.
    func didLayout() {
        if let column = outline.tableColumns.first, abs(column.width - scroll.contentSize.width) > 0.5 {
            column.width = scroll.contentSize.width
        }
        if let item = pendingReveal, scroll.contentSize.height >= outline.rowHeight * 3 {
            pendingReveal = nil
            DispatchQueue.main.async { [weak self] in self?.reveal(item) }
        }
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
        reflectSelection()
    }

    /// A split's side is drawn by its split's row.
    /// With `folders`, the folders it's in too, whose rows show what's inside them (sound).
    func reloadItem(_ item: SidebarItem, folders: Bool = false) {
        let row = space.row(of: item)
        if folders {
            var parent = space.location(of: row)?.parent
            while let folder = parent {
                if folder !== renaming, outline.row(forItem: folder) >= 0 { outline.reloadItem(folder, reloadChildren: false) }
                parent = space.location(of: folder)?.parent
            }
        }
        guard row !== renaming, outline.row(forItem: row) >= 0 else { return }
        outline.reloadItem(row, reloadChildren: false)
        if let id = selectedID, row.allTabs.contains(where: { $0.id == id }) { reflectSelection() }
    }

    /// The active tab is the window's (`WindowState`) and nothing else: the table's own selection is never used,
    /// so nothing AppKit does with rows (type-select, arrows, reloads, expanding) can switch tabs.
    func reflectSelection() {
        let active = selectedID.flatMap { space.find($0) }.map { space.row(of: $0) }
        outline.enumerateAvailableRowViews { rowView, row in
            (rowView as? SidebarRowView)?.isActive = active != nil && outline.item(atRow: row) as AnyObject === active
        }
    }

    /// Opens the folders around a tab the user just switched to and scrolls it into view.
    func reveal(_ side: SidebarItem) {
        let item = space.row(of: side)
        var parent = space.location(of: item)?.parent
        while let folder = parent, folder !== space.favorites {
            if !outline.isItemExpanded(folder) { Self.animateRows { outline.animator().expandItem(folder) } }
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
        outline.window?.makeFirstResponder(label)
        if let editor = label.currentEditor() as? NSTextView {
            editor.drawsBackground = false
            editor.backgroundColor = .clear
            editor.insertionPointColor = .labelColor
            let length = label.stringValue.utf16.count
            editor.selectedRange = selectAll ? NSRange(location: 0, length: length) : NSRange(location: length, length: 0)
            // A long name shows its end, where the caret is, not its start.
            editor.scrollRangeToVisible(NSRange(location: length, length: 0))
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
        if let label, outline.window?.firstResponder === label.currentEditor() { outline.window?.makeFirstResponder(nil) }
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
        let picker = IconPicker(selected: item.icon ?? "folder",
                                tint: NSColor(hex: space.colorHex)) { [weak self] symbol in
            item.icon = symbol == "folder" ? nil : symbol
            self?.outline.reloadItem(item, reloadChildren: false)
            self?.delegate?.sidebarChanged()
        }
        picker.present(relativeTo: outline.rect(ofRow: row).insetBy(dx: 10, dy: 0), of: outline, edge: .maxX)
    }

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
        case let item as SidebarItem where item.isSplit:
            delegate?.sidebarSelect(side(of: item, row: row), cause: "sidebar-click")
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
        if item.isFolder { toggleFolder(item) } else if item.isTab { rename(item) }
    }

    /// The side of a split's row the pointer is over; the split itself (its last side in front) when that can't tell.
    private func side(of split: SidebarItem, row: Int) -> SidebarItem {
        guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SplitCell,
              let event = outline.window?.currentEvent else { return split }
        let index = cell.side(at: cell.convert(event.locationInWindow, from: nil))
        return split.children.indices.contains(index) ? split.children[index] : split
    }

    func toggleFolder(_ folder: SidebarItem) {
        Self.animateRows {
            if outline.isItemExpanded(folder) { outline.animator().collapseItem(folder) } else { outline.animator().expandItem(folder) }
        }
    }

    /// A folder opens and closes quickly, starting fast and settling: AppKit's own takes about a third of a second and
    /// eases in, which read as a pause before anything moved.
    static func animateRows(_ changes: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            changes()
        }
    }

    /// A middle click closes the tab under it: in a split, that side, as its close button does.
    private func middleClicked(_ row: Int) {
        guard let item = outline.item(atRow: row) as? SidebarItem, !item.isFolder else { return }
        if item.isSplit { delegate?.sidebarClosePane(side(of: item, row: row)) } else { delegate?.sidebarClose(item) }
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
        // A split's two tabs are drawn in its own row, not as rows under it.
        return item.isFolder ? item.children.count : 0
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
        row.isActive = (item as? SidebarItem).map { item in item.allTabs.contains { $0.id == selectedID } || item.id == selectedID } ?? false
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
        if item.isSplit { return splitCell(item, in: outlineView) }
        let cell = (outlineView.makeView(withIdentifier: SidebarCell.identifier, owner: nil) as? SidebarCell) ?? SidebarCell()
        let pinned = space.isPinned(item)
        let loaded = delegate?.sidebarIsLoaded(item) ?? false
        cell.configure(item: item,
                       icon: item.isFolder ? nil : delegate?.sidebarFavicon(for: item),
                       loaded: item.isFolder || !pinned || loaded,
                       loading: delegate?.sidebarIsLoading(item) ?? false,
                       closable: !item.isFolder,
                       tint: NSColor(hex: space.colorHex),
                       unread: item.isUnread,
                       count: item.isLive ? item.unreadCount : 0,
                       sound: delegate?.sidebarSound(item) ?? .silent)
        cell.setCloseStyle(pinned: pinned, loaded: loaded)
        cell.onClose = { [weak self] in self?.delegate?.sidebarClose(item) }
        cell.onSound = { [weak self] in self?.delegate?.sidebarToggleSound(item) }
        return cell
    }

    private func splitCell(_ split: SidebarItem, in outlineView: NSOutlineView) -> NSView {
        let cell = (outlineView.makeView(withIdentifier: SplitCell.identifier, owner: nil) as? SplitCell) ?? SplitCell()
        let sides = split.children
        let pinned = space.isPinned(split)
        let loaded = sides.map { delegate?.sidebarIsLoaded($0) ?? false }
        cell.configure(split: split,
                       icons: sides.map { delegate?.sidebarFavicon(for: $0) },
                       loaded: loaded.map { !pinned || $0 },
                       loading: sides.map { delegate?.sidebarIsLoading($0) ?? false },
                       focused: sides.firstIndex { $0.id == selectedID },
                       closeTip: pinned ? L("tab.removePinned.tip") : L("tab.close"),
                       sounds: sides.map { delegate?.sidebarSound($0) ?? .silent })
        cell.onClose = { [weak self] index in
            guard split.children.indices.contains(index) else { return }
            self?.delegate?.sidebarClosePane(split.children[index])
        }
        cell.onSound = { [weak self] index in
            guard split.children.indices.contains(index) else { return }
            self?.delegate?.sidebarToggleSound(split.children[index])
        }
        return cell
    }

    // MARK: drag and drop

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

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard let moving = draggedItem(info), let target = drop.target(at: info.draggingLocation, moving: moving) else {
            pendingDrop = nil
            dropIndicator.hide()
            return []
        }
        pendingDrop = target
        dropIndicator.show(line: drop.line(for: target), group: drop.group(for: target), onto: target.onto, in: outline)
        if target.onto, case let .folder(folder) = target.container {
            outlineView.setDropItem(folder, dropChildIndex: NSOutlineViewDropOnItemIndex)
        } else {
            let (parent, child) = drop.outlinePosition(target.container, target.index)
            outlineView.setDropItem(parent, dropChildIndex: child)
        }
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        defer { pendingDrop = nil }
        guard let moving = draggedItem(info), let target = pendingDrop ?? drop.target(at: info.draggingLocation, moving: moving) else {
            return false
        }
        return move(moving, to: target.container, at: target.index)
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                     forItems draggedItems: [Any]) {
        // A tab can also be let go over the page, to open beside it, or over the favourites.
        delegate?.sidebarDragBegan()
        onDrag?(true)
        guard let folder = draggedItems.first as? SidebarItem, folder.isFolder, outlineView.isItemExpanded(folder) else { return }
        foldedForDrag = folder
        outlineView.collapseItem(folder)
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                     operation: NSDragOperation) {
        delegate?.sidebarDragEnded()
        onDrag?(false)
        guard let folder = foldedForDrag else { return }
        foldedForDrag = nil
        if outlineView.row(forItem: folder) >= 0 { outlineView.expandItem(folder) }
    }

    /// The one place a sidebar item changes position within the space; what a list may hold is the model's business
    /// (`Space.move`): pins and folders give a tab a home URL, Today takes it away, folders stay among the pins.
    @discardableResult
    func move(_ moving: SidebarItem, to container: Space.Slot, at index: Int) -> Bool {
        guard space.location(of: moving) != nil else { return false }
        if case let .folder(folder) = container, space.contains(moving, descendant: folder) { return false }
        space.move(moving, to: container, at: index)
        reload()
        onMove?()
        delegate?.sidebarChanged()
        return true
    }

    // MARK: context menu

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.contextRow
        let clicked = row >= 0 ? outline.item(atRow: row) as? SidebarItem : nil
        guard let item = clicked else {
            guard let full = emptyAreaMenu?() else { return }
            for entry in full.items {
                full.removeItem(entry)
                menu.addItem(entry)
            }
            return
        }
        if item.isSplit { return splitMenu(item, into: menu) }
        if item.isFolder {
            if item.isLive {
                menu.addItem(ClosureMenuItem(L("live.refresh")) { [weak self] in self?.delegate?.sidebarRefreshLive(item) })
                if item.unreadCount > 0 {
                    menu.addItem(ClosureMenuItem(L("live.markRead")) { [weak self] in self?.delegate?.sidebarMarkRead(item) })
                }
                menu.addItem(ClosureMenuItem(L("live.unfollow")) { [weak self] in self?.delegate?.sidebarUnfollow(item) })
                menu.addItem(.separator())
            }
            menu.addItem(ClosureMenuItem(L("item.rename")) { [weak self] in DispatchQueue.main.async { self?.rename(item) } })
            menu.addItem(ClosureMenuItem(L("folder.icon")) { [weak self] in self?.pickIcon(for: item) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(L("folder.delete")) { [weak self] in self?.delegate?.sidebarDeleteFolder(item) })
            return
        }
        let pinned = space.isPinned(item)
        menu.addItem(ClosureMenuItem(pinned ? L("tab.unpin") : L("tab.pin")) { [weak self] in self?.delegate?.sidebarTogglePin(item) })
        menu.addItem(ClosureMenuItem(L("favorites.add")) { [weak self] in self?.delegate?.sidebarFavorite(item, at: nil) })
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
        switch delegate?.sidebarSound(item) ?? .silent {
        case .playing: menu.addItem(ClosureMenuItem(L("tab.mute")) { [weak self] in self?.delegate?.sidebarToggleSound(item) })
        case .muted: menu.addItem(ClosureMenuItem(L("tab.unmute")) { [weak self] in self?.delegate?.sidebarToggleSound(item) })
        case .silent: break
        }
        menu.addItem(ClosureMenuItem(L("tab.copyLink")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.url, forType: .string)
        })
        if delegate?.sidebarCanSplit(item) == true {
            menu.addItem(ClosureMenuItem(L("split.open")) { [weak self] in self?.delegate?.sidebarSplit(item) })
        }
        if delegate?.sidebarCanFollow(item.url) == true {
            menu.addItem(ClosureMenuItem(L("live.follow")) { [weak self] in self?.delegate?.sidebarFollow(item.url) })
        }
        addMoveToSpace(item, to: menu)
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

/// The list's scroll view. With AppKit's responsive scrolling a trackpad gesture that starts over the list is followed
/// off the app's event path, so the window's space swipe (`SpaceSwipe`) never saw it: two fingers sideways only switched
/// spaces over the space bar. The list opts out (`SidebarOutline` too) and its scroll events reach the window.
final class SidebarScroll: ThinScrollView {
    override class var isCompatibleWithResponsiveScrolling: Bool { false }
}

extension SidebarList {
    /// A split's menu: separate it, swap the sides of a two-tab one, pin it, move it, close it.
    fileprivate func splitMenu(_ split: SidebarItem, into menu: NSMenu) {
        menu.addItem(ClosureMenuItem(L("split.separate")) { [weak self] in self?.delegate?.sidebarSeparate(split) })
        if split.children.count == 2 {
            menu.addItem(ClosureMenuItem(L("split.swap")) { [weak self] in self?.delegate?.sidebarSwapSides(split) })
        }
        menu.addItem(.separator())
        let pinned = space.isPinned(split)
        menu.addItem(ClosureMenuItem(pinned ? L("tab.unpin") : L("tab.pin")) { [weak self] in self?.delegate?.sidebarTogglePin(split) })
        addMoveToSpace(split, to: menu)
        menu.addItem(.separator())
        if pinned, split.children.contains(where: { delegate?.sidebarIsLoaded($0) ?? false }) {
            menu.addItem(ClosureMenuItem(L("tab.unload")) { [weak self] in self?.delegate?.sidebarClose(split) })
        }
        menu.addItem(ClosureMenuItem(pinned ? L("tab.removePinned") : L("split.close")) { [weak self] in
            if pinned { self?.delegate?.sidebarRemove(split) } else { self?.delegate?.sidebarClose(split) }
        })
    }

    fileprivate func addMoveToSpace(_ item: SidebarItem, to menu: NSMenu) {
        let others = store.state.spaces.filter { $0 !== space }
        guard !others.isEmpty else { return }
        let move = NSMenuItem(title: L("tab.moveToSpace"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for target in others {
            let entry = ClosureMenuItem(target.name) { [weak self] in self?.delegate?.sidebarMove(item, to: target) }
            entry.image = Glyphs.image(target.symbol, filled: false, pointSize: 13)
            sub.addItem(entry)
        }
        move.submenu = sub
        menu.addItem(move)
    }
}

#if DRIFT_DEV
extension SidebarList {
    func debugCommitRename(_ title: String) -> Bool {
        guard let field = renameLabel, outline.window?.firstResponder === field.currentEditor() else { return false }
        field.stringValue = title
        endRename(commit: true)
        return true
    }
}
#endif
