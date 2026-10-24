import AppKit

/// One browser window: its sidebar, the page beside it and everything between them and the engine.
///
/// The class holds the window's state and its core actions (selecting, opening, closing, spaces); the rest lives in
/// extensions next to it: `+Layout` (sidebar modes, the space's look), `+Sidebar` (the sidebar's requests),
/// `+Events` (the engine's pages and window), `+Downloads` and `+Prompts` (cards). Members those files share are
/// internal rather than private for that reason.
final class BrowserWindowController: NSObject, ArdiaCoreWindowDelegate, TabRuntimeDelegate, SidebarViewDelegate {
    let store: Store
    /// Where the browser-wide settings live: the main window's store, which a private window shares.
    let preferences: Store
    let profile: ArdiaCoreProfile
    let coreWindow: ArdiaCoreWindow
    let runtime: TabRuntime
    private(set) lazy var extensions = ExtensionsController(controller: self)

    let root = RootView()
    let sidebar: SidebarView
    let content = ContentView()
    private let emptyState = StartPage()
    private lazy var commandBar = CommandBar(controller: self)
    private(set) lazy var findBar = FindBar(controller: self)
    private lazy var spaceSwipe = SpaceSwipe(sidebar: sidebar, hasSeveralSpaces: { [weak self] in (self?.state.spaces.count ?? 0) > 1 },
                                             neighbour: { [weak self] offset in self?.neighbourSpace(towards: offset) },
                                             arrive: { [weak self] target in self?.switchSpace(to: target) })

    private(set) var shownTab: ArdiaCoreTab?
    var contentFullscreen = false
    var enteredWindowFullscreen = false
    /// The thin bar across the top of the page while it loads.
    private(set) lazy var loadingBar: LoadingBar = {
        let bar = LoadingBar(frame: .zero)
        root.addSubview(bar)
        return bar
    }()

    /// The loading capsule sits in the window's frame, centred above the page; with no frame (full screen) it
    /// lies on the page's top edge.
    func placeLoadingBar() {
        let page = content.frame
        let size = LoadingBar.size
        let band = root.bounds.height - page.maxY
        let y = band >= size.height + 2 ? page.maxY + (band - size.height) / 2 : page.maxY - size.height - 4
        loadingBar.frame = NSRect(x: page.midX - size.width / 2, y: y, width: size.width, height: size.height)
    }
    private(set) lazy var sitePrompts = SitePrompts(host: content, activeTab: { [weak self] in self?.shownTab })
    var devToolsViews: [ObjectIdentifier: NSView] = [:]
    /// NSEvent hands monitors back as opaque tokens (`Any`); they only go back to removeMonitor.
    private var monitors: [Any] = []
    /// Notification observers, removed with the window (a private window comes and goes; the main one lives on).
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    var overlayShown = false
    var overlayHide: DispatchWorkItem?
    var downloadsObserver: UUID?
    weak var downloadsPopover: NSPopover?
    /// Archives stale Today tabs while the browser runs.
    private var archiveTimer: Timer?

    /// The view in-window overlays (extension popups) are laid into.
    var overlayHost: NSView { root }
    private(set) lazy var history = HistoryIndex(profile: profile)
    var state: AppState { store.state }
    var space: Space { state.currentSpace }
    var window: NSWindow { coreWindow.window }

    var activeItem: SidebarItem? {
        guard let id = space.selectedID else { return nil }
        return space.find(id)
    }

    var activeTab: ArdiaCoreTab? {
        activeItem.flatMap { runtime.liveTab(for: $0) }
    }

    /// An incognito window: an off-the-record profile and a sidebar kept only in memory.
    var isPrivate: Bool { profile.offTheRecord }

    /// The browser-wide settings (search engine, archiving, the blocker…), the same in every window.
    var settings: BrowserSettings { preferences.state.settings }

    /// `preferences` is the main window's store for a private window, whose own store only holds its sidebar.
    init(store: Store, profile: ArdiaCoreProfile, preferences: Store? = nil) {
        self.store = store
        self.preferences = preferences ?? store
        self.profile = profile
        coreWindow = ArdiaCoreWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820))
        runtime = TabRuntime(coreWindow: coreWindow, profile: profile)
        sidebar = SidebarView(store: store)
        super.init()
        coreWindow.delegate = self
        coreWindow.prepare(profile)
        coreWindow.activeProfile = profile
        runtime.delegate = self
        sidebar.delegate = self
        configureWindow()
        buildViews()
        installMonitors()
        observeDownloads()
        applySpace()
        applySidebarMode(animated: false)
        applySettings()
        archiveTimer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { [weak self] _ in self?.archiveStaleToday() }
    }

    private func configureWindow() {
        window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = L("app.name")
        window.minSize = NSSize(width: 720, height: 460)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.backgroundColor = .windowBackgroundColor
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior.insert(.fullScreenPrimary)
        if isPrivate {
            window.center()
            window.setFrameOrigin(NSPoint(x: window.frame.minX + 40, y: window.frame.minY - 40))
        } else {
            if !window.setFrameUsingName("DriftMain") { window.center() }
            window.setFrameAutosaveName("DriftMain")
        }
        TrafficLights.install(on: window)
        // Coming back from another app, AppKit may leave no window key; then clicks only focus the window
        // and cursor changes stop, so the browser window takes key status back itself.
        observe(NSApplication.didBecomeActiveNotification, object: nil) { [weak self] _ in
            DispatchQueue.main.async { self?.reclaimKeyWindow() }
            // A password manager installed while Drift ran becomes reachable for its extension.
            DispatchQueue.global(qos: .utility).async { PasswordManagers.sync(into: Paths.chromium) }
        }
        // Chrome's own browser window hands the keyboard back to the page whenever it becomes key again; this one is
        // ours, so it does that here. Without it, after ⌘-Tab or un-minimising the page lost focus and ⌘A, ⌘C…
        // went nowhere.
        // A minimised window's Dock tile carries the icon file inside the bundle in its corner, not the chosen
        // icon; with another icon chosen the tile is drawn here: the window as it looked, with that icon on it.
        observe(NSWindow.willMiniaturizeNotification, object: window) { [weak self] _ in
            self?.drawMiniaturizedTile()
        }
        let iconChanged = IconChoice.onChange { [weak self] in
            guard let self, window.isMiniaturized else { return }
            if IconChoice.current == IconChoice.ids[0] {
                window.dockTile.contentView = nil
            } else if let tile = window.dockTile.contentView as? MiniaturizedTile {
                tile.badge = IconChoice.image(IconChoice.current)
            }
            window.dockTile.display()
        }
        observers.append((NotificationCenter.default, iconChanged))
        observe(NSWindow.didDeminiaturizeNotification, object: window) { [weak self] _ in
            self?.window.dockTile.contentView = nil
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification] {
            observe(name, object: window) { [weak self] note in
                DispatchQueue.main.async { self?.restorePageFocus(after: note.name.rawValue) }
            }
        }
        observe(Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, in: DistributedNotificationCenter.default()) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.applyTheme(of: self.space) }
        }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observe(name, object: window) { [weak self] _ in
                guard let self else { return }
                TrafficLights.retile(window)
                applySidebarMode(animated: false)
            }
        }
    }

    private func buildViews() {
        let host = coreWindow.hostView
        root.frame = host.bounds
        root.autoresizingMask = [.width, .height]
        host.addSubview(root)

        root.sidebarWidth = state.sidebarWidth
        root.install(sidebar: sidebar, content: content)
        Updater.shared.observe { [weak self] state in
            if case let .ready(version) = state { self?.sidebar.showUpdate(version) } else { self?.sidebar.showUpdate(nil) }
        }
        root.onSidebarResize = { [weak self] width in
            self?.state.sidebarWidth = width
            self?.store.setNeedsSave()
        }
        root.onCollapse = { [weak self] in
            guard let self, !state.sidebarHidden else { return }
            state.sidebarHidden = true
            overlayShown = false
            applySidebarMode(animated: true, duration: RootView.collapseDuration)
            store.setNeedsSave()
        }
        root.onExpand = { [weak self] in
            guard let self, state.sidebarHidden else { return }
            state.sidebarHidden = false
            overlayShown = false
            applySidebarMode(animated: true, duration: RootView.collapseDuration)
            store.setNeedsSave()
        }

        content.addSubview(emptyState)
        content.emptyState = emptyState
        emptyState.onSearch = { [weak self] in self?.showCommandBar(editing: false) }
        emptyState.onOpen = { [weak self] url in self?.openInNewTab(url) }
        emptyState.onReopen = { [weak self] index in self?.reopenClosedTab(at: index) }
        emptyState.onHide = { [weak self] host in
            guard let self else { return }
            updateSettings { $0.hiddenTopSites.append(host) }
            refreshStartPage()
        }
        content.onLayout = { [weak self] in
            self?.layoutTab()
            self?.placeLoadingBar()
        }
    }

    /// Chrome's window routes presses to its own views first, so drags, the hidden sidebar's edge
    /// and space swipes are caught here, before Chrome sees them.
    private func installMonitors() {
        let down = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window === window else { return event }
            // A press into the browser window while it isn't key (just after ⌘Tab, say) would only make it key;
            // making it key first lets this very press act.
            // After some ⌘-Tab switches macOS shows Archidea in front (its menu bar is up) while AppKit still has it
            // inactive with no key window. Presses then reach the window, but the sidebar list ignores them until
            // the app is active again, so a press while inactive activates the app itself, not only the window.
            if !NSApp.isActive {
                NSApp.activate()
                Trace.log("press while the app is inactive; activating it (active now \(NSApp.isActive))")
            }
            if !window.isKeyWindow {
                Trace.log("press into a non-key window; making it key (key was \(NSApp.keyWindow.map { NSStringFromClass(type(of: $0)) } ?? "none"))")
                window.makeKeyAndOrderFront(nil)
            }
            Trace.log("press \(event.type == .leftMouseDown ? "left" : "right") key=\(window.isKeyWindow) active=\(NSApp.isActive) "
                + "on \(WindowDrag.probe(event.locationInWindow, in: window))")
            guard event.type == .leftMouseDown else { return event }
            if commandBar.isOpen {
                // The bar sits over the whole window; a press in the sidebar closes it and goes on to the sidebar.
                if sidebarTakesPress(at: event.locationInWindow) { commandBar.hide() }
                return event
            }
            if overlayShown, !sidebar.frame.insetBy(dx: -6, dy: 0).contains(root.convert(event.locationInWindow, from: nil)) { setOverlay(false) }
            return WindowDrag.handle(event, in: window) ? nil : event
        }
        if Trace.enabled {
            // For focus reports: every ⌘ key as it arrives, with the window it goes to and who holds the keyboard.
            let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.modifierFlags.contains(.command) {
                    let key = NSApp.keyWindow
                    Trace.log("key ⌘\(event.charactersIgnoringModifiers ?? "?") arrives: event window=\(event.window.map { NSStringFromClass(type(of: $0)) } ?? "none"), "
                        + "key window=\(key.map { NSStringFromClass(type(of: $0)) } ?? "none"), "
                        + "first responder=\(key?.firstResponder.map { NSStringFromClass(type(of: $0)) } ?? "none"), active=\(NSApp.isActive)")
                }
                return event
            }
            monitors += [keys].compactMap { $0 }
        }
        // On the start page, typing goes straight into the address bar, which opens with the first letter in it.
        let typed = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === window, !emptyState.isHidden, !commandBar.isOpen,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !(window.firstResponder is NSTextView),
                  let text = event.characters, !text.isEmpty,
                  text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }),
                  !text.trimmingCharacters(in: .whitespaces).isEmpty else { return event }
            commandBar.show(in: root, typing: text, over: startSearchFrame)
            return nil
        }
        monitors += [typed].compactMap { $0 }
        let moved = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.trackPointer(event)
            return event
        }
        let scroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === window else { return event }
            return spaceSwipe.handle(event, at: root.convert(event.locationInWindow, from: nil)) ? nil : event
        }
        monitors += [down, moved, scroll].compactMap { $0 }
    }

    // MARK: settings

    /// Changes the browser-wide settings and has every window take them up.
    func updateSettings(_ change: (inout BrowserSettings) -> Void) {
        var next = preferences.state.settings
        change(&next)
        preferences.state.settings = next
        preferences.setNeedsSave()
        if let app = NSApp.delegate as? AppDelegate { app.settingsChanged() } else { settingsChanged() }
    }

    /// The settings changed (in this window or another): the parts that read them take them up again.
    func settingsChanged() {
        applySettings()
        sidebar.updateAddress(activeTab)
        sidebar.reload()
    }

    /// The address bar's search and full-URL switches are app-wide, so every window sets them from the same settings;
    /// the blocker is loaded into the normal profile only.
    private func applySettings() {
        URLInput.engine = settings.searchEngine
        AddressPill.showsFullURL = settings.showFullURL
        runtime.unloadMinutes = settings.unloadMinutes
        if !isPrivate { AdBlocker.apply(settings.adBlock, to: profile) }
    }

    func showWindow() {
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: selection

    func select(_ item: SidebarItem, focusPage: Bool = true, cause: String = "unspecified") {
        Trace.log("activate \(item.traceName) cause=\(cause) was=\(activeItem?.traceName ?? "-")")
        if let owner = state.space(containing: item), owner !== space {
            state.currentSpaceID = owner.id
            applySpace(selecting: false)
        }
        space.selectedID = item.id
        item.lastActive = Date()
        sidebar.reveal(item)
        store.setNeedsSave()
        guard !item.isFolder else { return }
        let tab = runtime.ensureTab(for: item)
        show(tab)
        expectActivation(of: tab)
        coreWindow.activate(tab)
        if focusPage { tab.focus() }
    }

    func show(_ tab: ArdiaCoreTab?) {
        if let old = shownTab, old !== tab {
            old.view.isHidden = true
            old.devToolsView?.isHidden = true
            old.noteShown(byHost: false)
            findBar.close()
        }
        shownTab = tab
        emptyState.isHidden = tab != nil
        if tab == nil { refreshStartPage() }
        sitePrompts.refresh()
        placeLoadingBar()
        loadingBar.show(loading: tab?.loading ?? false, progress: tab?.progress ?? 0, animated: false)
        guard let tab else { sidebar.updateAddress(nil); return }
        if let item = runtime.item(for: tab) { sidebar.reloadItem(item) }
        if tab.view.superview !== content { content.addSubview(tab.view, positioned: .below, relativeTo: nil) }
        tab.view.isHidden = false
        tab.noteShown(byHost: true)
        layoutTab()
        sidebar.updateAddress(tab)
    }

    func layoutTab() {
        guard let tab = shownTab else { return }
        let bounds = content.bounds
        if let devTools = tab.devToolsView {
            var devFrame = NSRect.zero, pageFrame = NSRect.zero
            tab.devToolsLayout(for: bounds.size, devTools: &devFrame, page: &pageFrame)
            // Below the page: the docked DevTools view can span the page's area too.
            if devTools.superview !== content { content.addSubview(devTools, positioned: .below, relativeTo: tab.view) }
            devTools.isHidden = false
            devTools.frame = devFrame
            tab.view.frame = pageFrame
        } else {
            tab.view.frame = bounds
        }
    }

    private func applySpace(selecting: Bool = true, direction: Int = 0) {
        applyTheme(of: space)
        sidebar.reload(direction: direction)
        guard selecting else { return }
        if let item = activeItem, !item.isFolder { select(item, cause: "space-restore") } else { show(nil) }
    }

    /// Everything in the current space, top to bottom, as the sidebar shows it.
    private var orderedTabs: [SidebarItem] { space.allTabs }

    func selectAdjacent(_ step: Int) {
        let list = orderedTabs
        guard !list.isEmpty else { return }
        let index = activeItem.flatMap { item in list.firstIndex { $0 === item } } ?? -step
        select(list[(index + step + list.count) % list.count], cause: "adjacent")
    }

    func selectTab(number: Int) {
        let list = orderedTabs
        guard !list.isEmpty else { return }
        select(number == 9 ? list[list.count - 1] : list[min(number, list.count) - 1], cause: "number")
    }

    // MARK: tabs

    /// A live page from another window (the mini window's, or one it opened) joins Today as it is.
    func adoptPage(_ tab: ArdiaCoreTab, foreground: Bool = true) {
        if foreground, commandBar.isOpen { commandBar.hide() }
        let item = SidebarItem(tab: tab.url, title: tab.title)
        if let icon = tab.favicon { store.setFavicon(icon, for: item) }
        space.today.insert(item, at: 0)
        // Bound first, so the engine's "tab inserted" for it is known as ours, not a new tab to adopt.
        runtime.bind(tab, to: item)
        coreWindow.adoptTab(tab)
        sidebar.reload()
        store.setNeedsSave()
        guard foreground else { return }
        // Chosen before the window shows, so it doesn't open on an empty page (and the new-tab bar with it).
        space.selectedID = item.id
        showWindow()
        NSApp.activate()
        DispatchQueue.main.async { [weak self] in self?.select(item, cause: "adopted-page") }
    }

    func openInNewTab(_ input: String) {
        // A tab opened from elsewhere (a link from another app, a menu) closes an open command bar.
        if commandBar.superview != nil { commandBar.hide() }
        let item = SidebarItem(tab: URLInput.resolve(input))
        space.today.insert(item, at: 0)
        sidebar.reload()
        select(item, cause: "new-tab")
    }

    func navigate(_ input: String) {
        guard let item = activeItem, !item.isFolder else { return openInNewTab(input) }
        let url = URLInput.resolve(input)
        item.url = url
        runtime.ensureTab(for: item).loadURL(url)
        select(item, cause: "navigate")
    }

    func closeSelected() {
        if findBar.isOpen { return findBar.close() }
        guard let item = activeItem, !item.isFolder else { return }
        close(item)
    }

    /// Closing an open pinned tab unloads it and keeps its place; closing a closed pinned tab, or a Today tab,
    /// takes it out of the list (⇧⌘T brings it back).
    /// `remembering` puts it on the reopen-closed-tab stack; a tab that only fetched a download isn't worth reopening.
    func close(_ item: SidebarItem, remembering: Bool = true) {
        if space.isPinned(item), runtime.liveTab(for: item) == nil { return remove(item) }
        let wasActive = item === activeItem
        let neighbor = wasActive ? neighbor(of: item) : nil
        unloadTab(item)
        if space.isPinned(item) {
            if let home = item.pinnedURL { item.url = home }
        } else {
            if remembering { state.remember(item) }
            space.remove(item)
        }
        if wasActive {
            space.selectedID = nil
            show(nil)
        }
        sidebar.reload()
        store.setNeedsSave()
        if let neighbor { select(neighbor, cause: "close-neighbor") }
    }

    /// Takes a tab (or a pin, open or not) out of the sidebar; ⇧⌘T brings it back, a pin to its place.
    func remove(_ item: SidebarItem) {
        let wasActive = item === activeItem
        state.remember(item)
        unloadTab(item)
        space.remove(item)
        if wasActive {
            space.selectedID = nil
            show(nil)
        }
        sidebar.reload()
        store.setNeedsSave()
    }

    /// Where the window goes when the tab in front closes: the next open tab below it, else the one above. A pin
    /// goes to an open Today tab, else another open pin, rather than to an empty window.
    private func neighbor(of item: SidebarItem) -> SidebarItem? {
        let isOpen = { (other: SidebarItem) in other !== item && self.runtime.liveTab(for: other) != nil }
        if space.isPinned(item) { return space.today.first(where: isOpen) ?? orderedTabs.first(where: isOpen) }
        let list = orderedTabs
        guard let index = list.firstIndex(where: { $0 === item }) else { return nil }
        return list[(index + 1)...].first(where: isOpen) ?? list[..<index].last(where: isOpen)
    }

    func togglePinSelected() {
        guard let item = activeItem, !item.isFolder else { return }
        togglePin(item)
    }

    func togglePin(_ item: SidebarItem) {
        guard !item.isFolder, let owner = state.space(containing: item) else { return }
        let pinning = !owner.isPinned(item)
        owner.remove(item)
        if pinning { owner.place(item, in: .pinned, at: owner.pinned.count) } else { owner.place(item, in: .today, at: 0) }
        sidebar.reload()
        sidebar.reflectSelection()
        store.setNeedsSave()
    }

    /// Today tabs Clear would close: everything except the active tab, tabs playing sound,
    /// and tabs used within the last `clearKeepsMinutes`.
    var clearableTabs: [SidebarItem] {
        let keepAfter = Date().addingTimeInterval(-Double(settings.clearKeepsMinutes) * 60)
        return space.today.filter { item in
            item !== activeItem && !(runtime.liveTab(for: item)?.audible ?? false) && item.lastActive < keepAfter
        }
    }

    func clearToday() {
        let closing = clearableTabs
        guard !closing.isEmpty else { return }
        for item in closing {
            state.remember(item)
            unloadTab(item)
            space.remove(item)
        }
        sidebar.reload()
        store.setNeedsSave()
    }

    /// Today tabs untouched for the archive time go while the browser runs too, not only at the next launch: all but
    /// each space's tab in front and those playing sound. They're on ⇧⌘T like any closed tab.
    func archiveStaleToday() {
        let hours = settings.archiveHours
        guard hours > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(hours) * 60 * 60)
        var archived = 0
        for owner in state.spaces {
            let stale = owner.staleToday(before: cutoff) { item in
                item.id == owner.selectedID || self.runtime.liveTab(for: item)?.audible == true
            }
            for item in stale {
                state.remember(item)
                unloadTab(item)
                owner.remove(item)
                archived += 1
            }
        }
        guard archived > 0 else { return }
        Trace.log("archived \(archived) Today tabs untouched for \(hours) h")
        sidebar.reload()
        store.setNeedsSave()
    }

    /// After switching back to Drift the key window can end up being one of Chrome's hidden helper windows, or none;
    /// then the first click only focuses, and cursor changes stop. Unless the user is in one of our own windows
    /// (settings, a sheet, a popover), the browser window takes key status back.
    private func reclaimKeyWindow() {
        guard window.isVisible, !window.isMiniaturized else { return }
        let key = NSApp.keyWindow
        Trace.log("app active, key window: \(key.map { NSStringFromClass(type(of: $0)) } ?? "none") visible=\(key?.isVisible ?? false)")
        if let key, key === window || key === window.attachedSheet { return }
        // Another browser window (a private one, say) keeps the keyboard it has.
        if let key, key.isVisible, key.identifier == TrafficLights.identifier { return }
        if let key, key.isVisible, key.alphaValue > 0, key === SettingsWindowController.shared.window
            || key.parent === window || key is NSPanel || NSStringFromClass(type(of: key)).contains("Popover") { return }
        window.makeKey()
    }

    /// Only needed when the chosen icon isn't the bundle's own: then the system's tile would carry the wrong one.
    /// The window is still on screen when this runs, so it's pictured as it looked.
    private func drawMiniaturizedTile() {
        window.dockTile.contentView = nil
        guard IconChoice.current != IconChoice.ids[0] else { return }
        guard let image = WindowPicture.take(window) else {
            return Trace.log("dock tile: no picture of the window; the system's tile shows")
        }
        showMiniaturizedTile(image)
    }

    private func showMiniaturizedTile(_ image: CGImage) {
        let tile = window.dockTile
        let view = MiniaturizedTile(frame: NSRect(origin: .zero, size: tile.size))
        view.snapshot = NSImage(cgImage: image, size: .zero)
        view.badge = IconChoice.image(IconChoice.current)
        tile.contentView = view
        tile.display()
    }

    /// Gives the keyboard back to the page unless something of ours holds it (the command bar, find, a rename,
    /// a card's field).
    private func restorePageFocus(after reason: String) {
        let responder = window.firstResponder
        let holder = (responder as? NSTextView)?.isFieldEditor == true ? (responder as? NSTextView)?.delegate as? NSView : responder as? NSView
        let ours = holder.map { view in
            view is NSTextField || sequence(first: view, next: \.superview).contains { $0 === commandBar || $0 === findBar }
        } ?? false
        Trace.log("focus after \(reason): first responder \(responder.map { NSStringFromClass(type(of: $0)) } ?? "none"), ours=\(ours)")
        // Even when the page view still is the first responder, the engine may have marked its contents unfocused
        // while the window was inactive; focusing again is cheap and puts the caret and ⌘A, ⌘C… back.
        guard !ours, window.isKeyWindow, let tab = activeTab else { return }
        tab.focus()
        Trace.log("focus: page takes the keyboard back")
    }

    // MARK: import

    /// Imported spaces and open tabs join the sidebar (see `AppState.adopt`).
    func adoptImported(spaces imported: [ImportedSpace], openTabs: [ImportedNode]) -> (spaces: Int, pins: Int, tabs: Int) {
        let counts = state.adopt(imported: imported, openTabs: openTabs) { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
        applySpace()
        store.setNeedsSave()
        return counts
    }

    // MARK: our own activations

    /// The tab we just made active (nil: we just closed or switched away), and until when Chrome's own
    /// activation notices count as echoes of that.
    var ownActivation: (tab: ArdiaCoreTab?, until: Date)?

    private func expectActivation(of tab: ArdiaCoreTab?) {
        ownActivation = (tab ?? ownActivation?.tab, Date().addingTimeInterval(1.5))
    }

    private func unloadTab(_ item: SidebarItem) {
        expectActivation(of: activeTab === runtime.liveTab(for: item) ? nil : activeTab)
        runtime.unload(item)
    }

    // MARK: recently closed

    /// The start page's contents, refreshed whenever it shows; history is read again if it's gone stale.
    private func refreshStartPage() {
        let fill = { [weak self] in
            guard let self, !emptyState.isHidden else { return }
            let sites = isPrivate ? [] : history.topSites(limit: 8, hidden: Set(settings.hiddenTopSites))
            let closed = state.recentlyClosed.suffix(4).reversed().map { StartPage.Closed(url: $0.url, title: $0.customTitle ?? $0.title) }
            emptyState.show(sites: sites, closed: closed)
        }
        fill()
        if !isPrivate { history.refresh(then: fill) }
    }

    /// One of the start page's recently closed tabs, counted from the newest.
    func reopenClosedTab(at index: Int) {
        guard state.bringForward(closedAt: index) else { return }
        reopenClosedTab()
    }

    /// ⇧⌘T: the newest closed tab comes back, a pin to its place, in its own space.
    func reopenClosedTab() {
        guard let reopened = state.reopenLastClosed() else { return }
        if reopened.space !== space { switchSpace(to: reopened.space) }
        sidebar.reload()
        select(reopened.item, cause: "reopen-closed")
    }

    func newFolder() {
        let folder = SidebarItem(folder: L("folder.new"))
        space.pinned.insert(folder, at: 0)
        sidebar.reload()
        sidebar.rename(folder, selectAll: true)
        store.setNeedsSave()
    }

    func copyURL() {
        guard let url = activeTab?.url ?? activeItem?.url, !url.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    func toggleDevTools() {
        guard let tab = activeTab else { return }
        if tab.devToolsView != nil { tab.closeDevTools() } else { tab.showDevTools() }
    }

    /// The start page's search field in the root view, while the start page is up.
    private var startSearchFrame: NSRect? {
        emptyState.isHidden ? nil : root.convert(emptyState.searchField.bounds, from: emptyState.searchField)
    }

    func showCommandBar(editing: Bool) {
        let sidebarVisible = !state.sidebarHidden || overlayShown
        let anchor = editing && sidebarVisible && !contentFullscreen
            ? root.convert(sidebar.addressAnchor.bounds, from: sidebar.addressAnchor) : nil
        if anchor == nil, overlayShown { setOverlay(false) }
        commandBar.show(in: root, editing: editing, current: editing ? (activeTab?.url ?? activeItem?.url) : nil, anchor: anchor,
                        over: startSearchFrame)
    }

    func commandBarDidHide() {
        if let tab = activeTab { tab.focus() } else { window.makeFirstResponder(nil) }
    }

    func showFind() {
        guard let tab = activeTab else { return }
        findBar.open(in: content, tab: tab)
    }

    // MARK: spaces

    func switchSpace(to target: Space) {
        expectActivation(of: nil)
        guard target !== space else { return }
        let from = state.spaces.firstIndex { $0 === space } ?? 0
        let to = state.spaces.firstIndex { $0 === target } ?? 0
        state.currentSpaceID = target.id
        applySpace(direction: to > from ? 1 : -1)
        store.setNeedsSave()
    }

    /// The space a swipe brings: fingers moving right the previous one, left the next. None past the ends.
    private func neighbourSpace(towards offset: CGFloat) -> Space? {
        guard offset != 0, let index = state.spaces.firstIndex(where: { $0 === space }) else { return nil }
        let target = index + (offset > 0 ? -1 : 1)
        return state.spaces.indices.contains(target) ? state.spaces[target] : nil
    }

    func switchSpace(by step: Int) {
        guard let index = state.spaces.firstIndex(where: { $0 === space }) else { return }
        switchSpace(to: state.spaces[(index + step + state.spaces.count) % state.spaces.count])
    }

    func newSpace() {
        ask(L("space.new.title"), placeholder: L("space.new.placeholder"), confirm: L("space.new.create")) { [weak self] name in
            guard let self else { return }
            let palette = SpaceStyle.palette
            let symbol = SpaceStyle.symbols[state.spaces.count % SpaceStyle.symbols.count]
            let created = Space(name: name, symbol: symbol, colorHex: palette[state.spaces.count % palette.count])
            state.spaces.append(created)
            switchSpace(to: created)
        }
    }

    func rename(_ target: Space) {
        ask(L("space.rename.title"), placeholder: target.name, value: target.name, confirm: L("space.rename.confirm")) { [weak self] name in
            target.name = name
            self?.sidebar.reload()
            self?.store.setNeedsSave()
        }
    }

    /// A space goes with everything in it, so one that holds tabs asks first.
    func delete(_ target: Space) {
        guard state.spaces.count > 1 else { return }
        let count = target.allTabs.count
        guard count > 0 else { return deleteNow(target) }
        confirm(host: target.name, icon: NSImage(systemSymbolName: target.symbol, accessibilityDescription: nil),
                title: L("space.delete.title", target.name), detail: L("space.delete.detail", plural("count.tabs", count)),
                confirm: L("space.delete.confirm")) { [weak self] in self?.deleteNow(target) }
    }

    private func deleteNow(_ target: Space) {
        guard state.spaces.count > 1, state.spaces.contains(where: { $0 === target }) else { return }
        for item in target.allTabs { unloadTab(item) }
        state.spaces.removeAll { $0 === target }
        if state.currentSpaceID == target.id {
            state.currentSpaceID = state.spaces[0].id
            applySpace()
        } else {
            sidebar.reload()
        }
        store.setNeedsSave()
    }

    /// To another space: a pin (or a folder, with everything in it) to the end of its pins, a Today tab to the top
    /// of its Today.
    func move(_ item: SidebarItem, to target: Space) {
        guard let from = state.space(containing: item), from !== target else { return }
        // The tab in front may be the item, or inside the folder that goes.
        let wasActive = from === space && activeItem.map { from.contains(item, descendant: $0) } == true
        let pinned = from.isPinned(item)
        from.remove(item)
        target.place(item, in: pinned ? .pinned : .today, at: pinned ? target.pinned.count : 0)
        if let selected = from.selectedID, from.find(selected) == nil { from.selectedID = nil }
        if wasActive { show(nil) }
        sidebar.reload()
        store.setNeedsSave()
    }

    private func observe(_ name: Notification.Name, object: NSWindow?, in center: NotificationCenter = .default,
                         _ block: @escaping (Notification) -> Void) {
        observers.append((center, center.addObserver(forName: name, object: object, queue: .main, using: block)))
    }

    /// A closing private window takes its event monitors, observers and timers with it; left behind they'd run on
    /// every mouse move for good.
    private func tearDown() {
        Trace.log("private window closes: \(monitors.count) event monitors, \(observers.count) observers go")
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
        downloadsObserver.map(Downloads.shared.stopObserving)
        downloadsObserver = nil
        runtime.stop()
        archiveTimer?.invalidate()
        archiveTimer = nil
        extensions.closePopup()
    }

    @objc(windowShouldClose:)
    func windowShouldClose(_ window: ArdiaCoreWindow) -> Bool {
        if isPrivate {
            // Closing a private window ends it: its tabs, and with them the off-the-record profile, go away.
            tearDown()
            (NSApp.delegate as? AppDelegate)?.privateWindowClosed(self)
            return true
        }
        store.saveNow()
        self.window.orderOut(nil)
        return false
    }

    /// Whether this window shows `tab`.
    func owns(_ tab: ArdiaCoreTab) -> Bool { runtime.item(for: tab) != nil }

    @objc(window:handleKeyEvent:)
    func window(_ window: ArdiaCoreWindow, handleKeyEvent event: NSEvent) -> Bool {
        let handled = NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
        if event.modifierFlags.contains(.command) {
            Trace.log("key ⌘\(event.charactersIgnoringModifiers ?? "?") from page → menu handled=\(handled), key window=\(self.window.isKeyWindow), "
                + "first responder=\(self.window.firstResponder.map { NSStringFromClass(type(of: $0)) } ?? "none")")
        }
        return handled
    }
}

#if DRIFT_DEV
extension BrowserWindowController {
    func debugType(_ text: String) { commandBar.debugType(text) }
    func debugHideCommandBar() { commandBar.hide() }
    func debugCommitRename(_ title: String) -> Bool { sidebar.debugCommitRename(title) }
    func debugReloadSidebar() { sidebar.reload() }
    func debugToggle(_ folder: SidebarItem) { sidebar.toggleFolder(folder) }
    var debugSidebar: SidebarView { sidebar }
    var debugCommandBar: CommandBar { commandBar }
    func debugSetOverlay(_ shown: Bool) { setOverlay(shown) }
    func debugSwipe(_ event: NSEvent) -> Bool { spaceSwipe.handle(event, at: NSPoint(x: sidebar.frame.midX, y: sidebar.frame.midY)) }
    var debugRoot: NSView { root }
    func debugResize(to x: CGFloat) { root.debugResize(to: x); root.layoutSubtreeIfNeeded() }
    func debugBeginResize() { root.debugBeginResize() }
    func debugEndResize() { root.debugEndResize() }
    var debugSidebarState: String { "hidden=\(state.sidebarHidden) overlay=\(overlayShown) width=\(Int(root.sidebarWidth)) frame=\(Int(sidebar.frame.minX))..\(Int(sidebar.frame.maxX))" }
    func debugClickRow(of item: SidebarItem) { sidebar.debugClickRow(of: item) }
    func debugTypeInSidebar(_ text: String) { sidebar.debugKey(characters: text, keyCode: 0) }
    func debugKeyInSidebar(_ keyCode: UInt16) { sidebar.debugKey(characters: "", keyCode: keyCode) }
    func debugRename(_ title: String) {
        if let folder = space.pinned.first(where: { $0.title == title }) { sidebar.rename(folder) }
    }
    func debugFrames() -> String {
        let host = coreWindow.hostView
        return "host=\(host.frame) in \(host.superview.map { NSStringFromClass(type(of: $0)) } ?? "-") root=\(root.frame) sidebar=\(sidebar.frame) content=\(content.frame) rootSubviews=\(root.subviews.map { NSStringFromClass(type(of: $0)) }) hostSubviews=\(host.subviews.map { NSStringFromClass(type(of: $0)) }) superSubviews=\(host.superview?.subviews.map { NSStringFromClass(type(of: $0)) } ?? [])"
    }
}
#endif
