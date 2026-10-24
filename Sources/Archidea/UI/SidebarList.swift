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

    func reloadItem(_ item: SidebarItem) {
        guard item !== renaming, outline.row(forItem: item) >= 0 else { return }
        outline.reloadItem(item, reloadChildren: false)
        if let id = selectedID, id == item.id { reflectSelection() }
    }

    /// The active tab is the window's (`WindowState`) and nothing else: the table's own selection is never used,
    /// so nothing AppKit does with rows (type-select, arrows, reloads, expanding) can switch tabs.
    func reflectSelection() {
        let active = selectedID.flatMap { space.find($0) }
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
        row.isActive = (item as? SidebarItem).map { $0.id == selectedID } ?? false
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
    func move(_ moving: SidebarItem, to container: Space.Slot, at index: Int) -> Bool {
        guard space.location(of: moving) != nil else { return false }
        if case let .folder(folder) = container, space.contains(moving, descendant: folder) { return false }
        space.move(moving, to: container, at: index)
        reload()
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
                entry.image = Glyphs.image(target.symbol, filled: false, pointSize: 13)
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

/// The list's scroll view. With AppKit's responsive scrolling a trackpad gesture that starts over the list is followed
/// off the app's event path, so the window's space swipe (`SpaceSwipe`) never saw it: two fingers sideways only switched
/// spaces over the space bar. The list opts out (`SidebarOutline` too) and its scroll events reach the window.
final class SidebarScroll: ThinScrollView {
    override class var isCompatibleWithResponsiveScrolling: Bool { false }
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
