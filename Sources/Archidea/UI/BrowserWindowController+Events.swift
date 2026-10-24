import AppKit
import ArchideaCore
import ArdiaCore

/// What the engine tells the window: its pages changing, opening, closing, and Chrome's window doing things of its own.
extension BrowserWindowController {
    // MARK: TabRuntimeDelegate: the live pages

    func runtime(_ runtime: TabRuntime, loadingOf tab: ArdiaCoreTab) {
        guard tab === shownTab else { return }
        placeLoadingBar()
        loadingBar.show(loading: tab.loading, progress: tab.progress)
    }

    /// Pages change all the time (loading, sound, back and forward); the sidebar is only written out again when
    /// what it keeps changed, and the icon only when the page has a new one.
    func runtime(_ runtime: TabRuntime, didUpdate item: SidebarItem, change: TabChange) {
        if change.contains(.favicon), let icon = runtime.liveTab(for: item)?.favicon { store.setFavicon(icon, for: item) }
        sidebar.reloadItem(item)
        group.itemChanged(item, by: self)
        if item === activeItem {
            sidebar.updateAddress(runtime.liveTab(for: item))
            if change.contains(.saved) { updateWindowTitle() }
        }
        if change.contains(.saved) { store.setNeedsSave() }
    }

    /// A page opened from a Today tab goes right above it, so the pages a tab opened sit by it in the order they were
    /// opened; from a pin, or from nowhere, it goes to the top of Today like a new tab. One opened in the background
    /// (a middle click, Open Link in New Tab) stays there.
    func runtime(_ runtime: TabRuntime, adopt tab: ArdiaCoreTab, opener: ArdiaCoreTab?, foreground: Bool) {
        let item = SidebarItem(tab: tab.url, title: tab.title)
        let from = opener.flatMap { runtime.item(for: $0) }
        let owner = from.flatMap { state.space(containing: $0) } ?? space
        let index = from.flatMap { source in owner.today.firstIndex { $0 === source } } ?? 0
        owner.today.insert(item, at: index)
        runtime.bind(tab, to: item)
        if owner === space { sidebar.reload() }
        group.sidebarChanged(by: self)
        if foreground {
            select(item, cause: "chrome-new-tab")
        } else {
            tab.view.isHidden = true
            // Chrome may make the new tab its active one, or the page may ask to come forward as it opens; the page
            // in front stays in front.
            ownActivation = (shownTab, Date().addingTimeInterval(1.5))
            openedBehind = (tab, Date().addingTimeInterval(1.5))
        }
        store.setNeedsSave()
    }

    func runtime(_ runtime: TabRuntime, downloadTookOver item: SidebarItem) {
        guard state.space(containing: item) === space, !space.isPinned(item) else { return }
        close(item, remembering: false)
    }

    func runtime(_ runtime: TabRuntime, tabDidClose item: SidebarItem) {
        guard let owner = state.space(containing: item) else { return }
        let wasActive = owner === space && item === activeItem
        if owner.isPinned(item) {
            if let home = item.pinnedURL { item.url = home }
        } else {
            owner.remove(item)
        }
        if wasActive {
            windowState.select(nil, in: owner)
            show(nil)
            if let next = owner.today.first(where: { runtime.liveTab(for: $0) != nil }) { select(next, cause: "tab-closed-neighbor") }
        }
        // Another window waiting for the page shows nothing in its place.
        group.unload(item)
        reloadSidebar()
        store.setNeedsSave()
    }

    func runtime(_ runtime: TabRuntime, tab: ArdiaCoreTab, didFindMatches count: Int32, active: Int32) {
        findBar.update(count: Int(count), active: Int(active))
    }

    func runtime(_ runtime: TabRuntime, tabNeedsActivation tab: ArdiaCoreTab) {
        if let behind = openedBehind, behind.tab === tab, Date() < behind.until {
            return Trace.log("ignored a request to activate a tab that just opened in the background")
        }
        if let item = runtime.item(for: tab), item !== activeItem { select(item, cause: "tab-requests-activation") }
    }

    // MARK: ArdiaCoreWindowDelegate: Chrome's own window

    @objc(window:didInsertTab:opener:disposition:)
    func window(_ window: ArdiaCoreWindow, didInsert tab: ArdiaCoreTab, opener: ArdiaCoreTab?, disposition: String) {
        guard !runtime.isMine(tab) else { return }
        Trace.log("chrome opened a tab: \(disposition), from \(opener.flatMap { runtime.item(for: $0)?.traceName } ?? "no tab")")
        runtime(runtime, adopt: tab, opener: opener, foreground: disposition != "new_background_tab")
    }

    @objc(window:didActivateTab:)
    func window(_ window: ArdiaCoreWindow, didActivate tab: ArdiaCoreTab) {
        // Chrome's tab strip also activates tabs as a side effect of what we do (closing the active tab picks a
        // neighbour, opening one shuffles the strip). Those echoes don't get to change the model's active tab.
        if let own = ownActivation, Date() < own.until {
            if let expected = own.tab, expected !== tab, !expected.closed {
                Trace.log("ignored chrome activation of \(runtime.item(for: tab)?.traceName ?? "a tab we don't know") (echo of our own change)")
                coreWindow.activate(expected)
            }
            return
        }
        if let item = runtime.item(for: tab), item !== activeItem { select(item, focusPage: false, cause: "chrome-did-activate") }
    }

    @objc(window:devToolsDidChangeForTab:view:)
    func window(_ window: ArdiaCoreWindow, devToolsDidChangeFor tab: ArdiaCoreTab, view: NSView?) {
        let key = ObjectIdentifier(tab)
        if let old = devToolsViews[key], old !== view { old.removeFromSuperview() }
        devToolsViews[key] = view
        if tab === shownTab { layoutTab() }
    }

    @objc(window:tab:didChangeFullscreen:)
    func window(_ window: ArdiaCoreWindow, tab: ArdiaCoreTab, didChangeFullscreen fullscreen: Bool) {
        contentFullscreen = fullscreen
        applySidebarMode(animated: false)
        let isFull = self.window.styleMask.contains(.fullScreen)
        if fullscreen, !isFull {
            enteredWindowFullscreen = true
            self.window.toggleFullScreen(nil)
        } else if !fullscreen, isFull, enteredWindowFullscreen {
            enteredWindowFullscreen = false
            self.window.toggleFullScreen(nil)
        }
    }

    @objc(window:passwordPrompt:forTab:)
    func window(_ window: ArdiaCoreWindow, passwordPrompt prompt: [String: Any], for tab: ArdiaCoreTab) {
        sitePrompts.addPasswordPrompt(prompt, tab: tab)
    }
}
