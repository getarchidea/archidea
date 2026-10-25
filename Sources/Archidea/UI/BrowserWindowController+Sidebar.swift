import AppKit
import ArchideaCore

/// What the sidebar asks of the window: most of it goes straight to the window's own actions.
extension BrowserWindowController {
    func sidebarSelect(_ item: SidebarItem, cause: String) { select(item, cause: cause) }
    func sidebarClose(_ item: SidebarItem) { close(item) }
    func sidebarTogglePin(_ item: SidebarItem) { togglePin(item) }
    func sidebarNewTab() { showCommandBar(editing: false) }
    func sidebarAddressClicked() { showCommandBar(editing: true) }
    func sidebarCopyURL() { copyURL() }

    func sidebarSiteControls(from view: NSView) {
        guard let tab = activeTab else { return }
        SiteControls(controller: self, tab: tab).present(from: view)
    }
    func sidebarBack() { activeTab?.goBack() }
    func sidebarForward() { activeTab?.goForward() }
    func sidebarReload() { activeTab?.reload() }
    func sidebarToggle() { toggleSidebar() }
    func sidebarSwitch(to target: Space) { switchSpace(to: target) }
    func sidebarNewSpace() { newSpace() }
    func sidebarRename(_ target: Space) { rename(target) }
    func sidebarDelete(_ target: Space) { delete(target) }
    func sidebarMove(_ item: SidebarItem, to target: Space) { move(item, to: target) }
    func sidebarNewFolder() { newFolder() }
    func sidebarClearToday() { clearToday() }
    func sidebarRemove(_ item: SidebarItem) { remove(item) }

    func sidebarClearableCount() -> Int { clearableTabs.count }
    func sidebarClosedCount() -> Int { state.recentlyClosed.count }
    func sidebarReopenClosed() { reopenClosedTab() }
    func sidebarEditTheme(_ target: Space, from view: NSView) { editTheme(target, from: view) }
    func sidebarManageSpaces() { SettingsWindowController.shared.show(section: .spaces) }
    func sidebarRestyle(_ target: Space, color: String?, symbol: String?) { restyle(target, color: color, symbol: symbol) }
    func sidebarChanged() {
        store.setNeedsSave()
        group.sidebarChanged(by: self)
    }
    func sidebarExtensions(from view: NSView) { extensions.showMenu(from: view) }

    func sidebarResetPin(_ item: SidebarItem) {
        guard let home = item.pinnedURL else { return }
        item.url = home
        group.liveTab(for: item)?.loadURL(home)
        sidebar.reloadItem(item)
        group.itemChanged(item, by: self)
        store.setNeedsSave()
    }

    func sidebarDeleteFolder(_ folder: SidebarItem) {
        guard let loc = space.location(of: folder) else { return }
        space.remove(folder)
        if let parent = loc.parent { parent.children.insert(contentsOf: folder.children, at: loc.index) }
        else { space.pinned.insert(contentsOf: folder.children, at: loc.index) }
        reloadSidebar()
        store.setNeedsSave()
    }

    func sidebarFavicon(for item: SidebarItem) -> NSImage? {
        if let image = group.liveTab(for: item)?.favicon { return image }
        if let image = store.favicon(for: item) { return image }
        // Not opened since it came in (an import, a link): the icon the engine has for its page or site.
        if let image = Favicons.shared.cached(item.url) { return image }
        Favicons.shared.lookUp(item.url) { [weak self, weak item] image in
            guard let self, let item else { return }
            store.setFavicon(image, for: item)
            sidebar.reloadItem(item)
        }
        return nil
    }

    /// New icons arrived for pages (an import stored them): rows ask again, in every window.
    func refreshFavicons() { reloadSidebar() }

    /// Open in any window: the sidebar is the same in all of them.
    func sidebarIsLoaded(_ item: SidebarItem) -> Bool {
        guard let tab = group.liveTab(for: item) else { return false }
        return !tab.discarded
    }

    func sidebarIsLoading(_ item: SidebarItem) -> Bool {
        group.liveTab(for: item)?.loading ?? false
    }

    // MARK: split view

    func sidebarCanSplit(_ item: SidebarItem) -> Bool { canSplit(with: item.id) }
    func sidebarSplit(_ item: SidebarItem) { split(with: item.id) }
    func sidebarSeparate(_ split: SidebarItem) { separate(split) }
    func sidebarClosePane(_ item: SidebarItem) { closePane(item) }
    func sidebarSwapSides(_ split: SidebarItem) { swapSides(split) }
    func sidebarDragBegan() { dragFromSidebarBegan() }
    func sidebarDragEnded() { dragFromSidebarEnded() }
}
