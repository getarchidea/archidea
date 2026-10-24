import AppKit

final class BrowserWindowController: NSObject, ArdiaCoreWindowDelegate, TabRuntimeDelegate, SidebarViewDelegate {
    let store: Store
    let profile: ArdiaCoreProfile
    let coreWindow: ArdiaCoreWindow
    let runtime: TabRuntime
    private(set) lazy var extensions = ExtensionsController(controller: self)

    private let root = RootView()
    private let sidebar: SidebarView
    private let content = ContentView()
    private let emptyState = EmptyStateView()
    private lazy var commandBar = CommandBar(controller: self)
    private lazy var findBar = FindBar(controller: self)

    private var shownTab: ArdiaCoreTab?
    private var contentFullscreen = false
    private var enteredWindowFullscreen = false
    /// The thin bar across the top of the page while it loads.
    private lazy var loadingBar: LoadingBar = {
        let bar = LoadingBar(frame: .zero)
        root.addSubview(bar)
        return bar
    }()

    /// The loading capsule sits in the window's frame, centred above the page; with no frame (full screen) it
    /// lies on the page's top edge.
    private func placeLoadingBar() {
        let page = content.frame
        let size = LoadingBar.size
        let band = root.bounds.height - page.maxY
        let y = band >= size.height + 2 ? page.maxY + (band - size.height) / 2 : page.maxY - size.height - 4
        loadingBar.frame = NSRect(x: page.midX - size.width / 2, y: y, width: size.width, height: size.height)
    }
    private lazy var sitePrompts = SitePrompts(host: content, activeTab: { [weak self] in self?.shownTab })
    private var devToolsViews: [ObjectIdentifier: NSView] = [:]
    private var monitors: [Any] = []
    private var overlayShown = false
    private var overlayHide: DispatchWorkItem?
    private var swipe: CGFloat = 0
    private var swipeConsumed = false

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

    init(store: Store, profile: ArdiaCoreProfile) {
        self.store = store
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
        URLInput.engine = state.settings.searchEngine
        runtime.unloadMinutes = state.settings.unloadMinutes
        AddressPill.showsFullURL = state.settings.showFullURL
        if !isPrivate { AdBlocker.apply(state.settings.adBlock, to: profile) }
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
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.reclaimKeyWindow() }
            // A password manager installed while Drift ran becomes reachable for its extension.
            DispatchQueue.global(qos: .utility).async { PasswordManagers.sync(into: Paths.chromium) }
        }
        // Chrome's own browser window hands the keyboard back to the page whenever it becomes key again; this one is
        // ours, so it does that here. Without it, after ⌘-Tab or un-minimising the page lost focus and ⌘A, ⌘C…
        // went nowhere.
        // A minimised window's Dock tile carries the bundle's own icon in its corner, not the chosen one;
        // the tile is drawn here instead: the window as it looked, with the chosen icon on it.
        NotificationCenter.default.addObserver(forName: NSWindow.willMiniaturizeNotification, object: window, queue: .main) { [weak self] _ in
            self?.drawMiniaturizedTile()
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main) { [weak self] _ in
            self?.window.dockTile.contentView = nil
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                DispatchQueue.main.async { self?.restorePageFocus(after: note.name.rawValue) }
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                                                            object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.applyTheme(of: self.space) }
        }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
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
            _ = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.modifierFlags.contains(.command) {
                    let key = NSApp.keyWindow
                    Trace.log("key ⌘\(event.charactersIgnoringModifiers ?? "?") arrives: event window=\(event.window.map { NSStringFromClass(type(of: $0)) } ?? "none"), "
                        + "key window=\(key.map { NSStringFromClass(type(of: $0)) } ?? "none"), "
                        + "first responder=\(key?.firstResponder.map { NSStringFromClass(type(of: $0)) } ?? "none"), active=\(NSApp.isActive)")
                }
                return event
            }
        }
        let moved = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.trackPointer(event)
            return event
        }
        let scroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === window else { return event }
            return swipeSpaces(event, at: root.convert(event.locationInWindow, from: nil)) ? nil : event
        }
        monitors = [down, moved, scroll].compactMap { $0 }
    }

    // MARK: sidebar modes

    private func applySidebarMode(animated: Bool, duration: TimeInterval = 0.22) {
        let mode: RootView.SidebarMode = !state.sidebarHidden ? .docked : overlayShown ? .overlay : .hidden
        root.mode = mode
        root.contentFullscreen = contentFullscreen
        let fullscreen = window.styleMask.contains(.fullScreen)
        TrafficLights.setVisible(fullscreen || (mode != .hidden && !contentFullscreen), in: window, animated: animated)
        if animated { root.animateLayout(duration: duration) } else { root.needsLayout = true }
    }

    /// Where the page sits, in `view`'s coordinates.
    func pageFrame(in view: NSView) -> NSRect { view.convert(content.bounds, from: content) }

    /// Whether a press at this window point lands on the sidebar while it's on screen, docked or slid out.
    func sidebarTakesPress(at point: NSPoint) -> Bool {
        guard !contentFullscreen, !state.sidebarHidden || overlayShown else { return false }
        return sidebar.frame.contains(root.convert(point, from: nil))
    }

    private func setOverlay(_ shown: Bool) {
        overlayHide?.cancel()
        overlayHide = nil
        guard overlayShown != shown, state.sidebarHidden else { return }
        overlayShown = shown
        applySidebarMode(animated: true)
    }

    private func trackPointer(_ event: NSEvent) {
        guard event.window === window, state.sidebarHidden, !contentFullscreen, !root.isResizing else { return }
        let point = root.convert(event.locationInWindow, from: nil)
        if !overlayShown {
            if point.x <= 6, point.y > 0, point.y < root.bounds.height { setOverlay(true) }
            return
        }
        if point.x > sidebar.frame.maxX + 24 {
            guard overlayHide == nil else { return }
            let work = DispatchWorkItem { [weak self] in self?.setOverlay(false) }
            overlayHide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        } else {
            overlayHide?.cancel()
            overlayHide = nil
        }
    }

    /// Two-finger horizontal swipe over the sidebar moves between spaces, like Arc.
    /// Two fingers across the sidebar page between spaces, as in Arc: the list follows the fingers (with a rubber
    /// band past the first and last space), and on letting go it either carries on to the neighbour — when pulled
    /// a quarter of the way or flicked — or springs back. The momentum after the fingers lift is swallowed.
    private func swipeSpaces(_ event: NSEvent, at point: NSPoint) -> Bool {
        guard event.hasPreciseScrollingDeltas, state.spaces.count > 1 else { return false }
        if event.momentumPhase != [] { return swipeConsumed }
        switch event.phase {
        case .began:
            guard sidebar.frame.contains(point) else { return false }
            swipe = 0
            swipeTracking = false
            swipeConsumed = false
            return false
        case .changed:
            guard sidebar.frame.contains(point) || swipeTracking else { return false }
            if !swipeTracking {
                guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.5, abs(event.scrollingDeltaX) > 1 else { return false }
                swipeTracking = true
            }
            swipe += event.scrollingDeltaX
            swipeVelocity = event.scrollingDeltaX
            let width = sidebar.bounds.width
            let hasNeighbour = neighbourSpace(towards: swipe) != nil
            sidebar.swipeOffset = hasNeighbour ? max(-width, min(width, swipe)) : swipe / 3
            return true
        case .ended, .cancelled:
            guard swipeTracking else { return false }
            swipeTracking = false
            swipeConsumed = true
            let width = sidebar.bounds.width
            let flick = abs(swipeVelocity) > 14 && (swipeVelocity > 0) == (swipe > 0)
            if event.phase == .ended, let next = neighbourSpace(towards: swipe), abs(swipe) > width * 0.25 || flick {
                let outward: CGFloat = swipe > 0 ? width : -width
                sidebar.settleSwipe(at: outward, duration: 0.16) { [weak self] in
                    guard let self else { return }
                    sidebar.swipeOffset = 0
                    switchSpace(to: next)
                }
            } else {
                sidebar.settleSwipe(at: 0, duration: 0.28)
            }
            swipe = 0
            return true
        default:
            return false
        }
    }

    private var swipeTracking = false
    private var swipeVelocity: CGFloat = 0

    /// The space a swipe moves to: fingers moving right bring the previous space, left the next one. None past the ends.
    private func neighbourSpace(towards offset: CGFloat) -> Space? {
        guard offset != 0, let index = state.spaces.firstIndex(where: { $0 === space }) else { return nil }
        let target = index + (offset > 0 ? -1 : 1)
        return state.spaces.indices.contains(target) ? state.spaces[target] : nil
    }

    /// Applies browser settings to the parts that read them.
    func settingsChanged() {
        URLInput.engine = state.settings.searchEngine
        runtime.unloadMinutes = state.settings.unloadMinutes
        AddressPill.showsFullURL = state.settings.showFullURL
        AdBlocker.apply(state.settings.adBlock, to: profile)
        sidebar.updateAddress(activeTab)
        sidebar.reload()
        store.setNeedsSave()
    }

    func showWindow() {
        window.makeKeyAndOrderFront(nil)
        if activeItem == nil { DispatchQueue.main.async { self.showCommandBar(editing: false) } }
    }

    // MARK: selection

    func select(_ item: SidebarItem, focusPage: Bool = true, cause: String = "unspecified") {
        Trace.log("activate \"\(item.displayTitle)\" cause=\(cause) was=\"\(activeItem?.displayTitle ?? "-")\"")
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

    private func show(_ tab: ArdiaCoreTab?) {
        if let old = shownTab, old !== tab {
            old.view.isHidden = true
            old.devToolsView?.isHidden = true
            old.noteShown(byHost: false)
            findBar.close()
        }
        shownTab = tab
        emptyState.isHidden = tab != nil
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

    private func layoutTab() {
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
            if remembering { remember(item) }
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

    private func neighbor(of item: SidebarItem) -> SidebarItem? {
        let list = space.isPinned(item) ? space.today : orderedTabs
        guard let index = list.firstIndex(where: { $0 === item }) else { return space.today.first }
        let rest = list.filter { $0 !== item && runtime.liveTab(for: $0) != nil }
        if rest.isEmpty { return nil }
        let after = list[(index + 1)...].first { $0 !== item && runtime.liveTab(for: $0) != nil }
        return after ?? rest.last
    }

    func togglePinSelected() {
        guard let item = activeItem, !item.isFolder else { return }
        togglePin(item)
    }

    func togglePin(_ item: SidebarItem) {
        space.remove(item)
        if item.pinnedURL == nil {
            item.pinnedURL = item.url
            space.pinned.append(item)
        } else {
            item.pinnedURL = nil
            space.today.insert(item, at: 0)
        }
        sidebar.reload()
        sidebar.reflectSelection()
        store.setNeedsSave()
    }

    /// Today tabs Clear would close: everything except the active tab, tabs playing sound,
    /// and tabs used within the last `clearKeepsMinutes`.
    var clearableTabs: [SidebarItem] {
        let keepAfter = Date().addingTimeInterval(-Double(state.settings.clearKeepsMinutes) * 60)
        return space.today.filter { item in
            item !== activeItem && !(runtime.liveTab(for: item)?.audible ?? false) && item.lastActive < keepAfter
        }
    }

    func clearToday() {
        let closing = clearableTabs
        guard !closing.isEmpty else { return }
        for item in closing {
            remember(item)
            unloadTab(item)
            space.remove(item)
        }
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

    private func drawMiniaturizedTile() {
        guard let snapshot = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                     [.boundsIgnoreFraming, .bestResolution]) else { return }
        let tile = window.dockTile
        let view = MiniaturizedTile(frame: NSRect(origin: .zero, size: tile.size))
        view.snapshot = NSImage(cgImage: snapshot, size: .zero)
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

    /// Imported spaces join the sidebar (one with the same name takes them in); open tabs go to the current Today.
    /// An untouched starting space is dropped when real ones arrive.
    func adoptImported(spaces imported: [ImportedSpace], openTabs: [ImportedNode]) -> (spaces: Int, pins: Int, tabs: Int) {
        var counts = (spaces: 0, pins: 0, tabs: 0)
        func symbolIfReal(_ name: String?) -> String? {
            name.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil ? $0 : nil }
        }
        func item(_ node: ImportedNode, pinned: Bool) -> SidebarItem? {
            switch node {
            case let .tab(url, title):
                guard !url.isEmpty else { return nil }
                let tab = SidebarItem(tab: url, title: title)
                if pinned { tab.pinnedURL = url }
                return tab
            case let .folder(title, symbol, children, expanded):
                let folder = SidebarItem(folder: title.isEmpty ? L("folder.new") : title)
                folder.icon = symbolIfReal(symbol)
                folder.expanded = expanded
                folder.children = children.compactMap { item($0, pinned: true) }
                return folder
            }
        }
        let untouched = state.spaces.count == 1 && space.pinned.isEmpty && space.today.isEmpty
        let starting = space
        for incoming in imported where !(incoming.pinned.isEmpty && incoming.tabs.isEmpty) {
            let target: Space
            if let existing = state.spaces.first(where: { $0.name == incoming.name }), !(untouched && existing === starting) {
                target = existing
            } else {
                let index = state.spaces.count
                target = Space(name: incoming.name,
                               symbol: symbolIfReal(incoming.symbol) ?? SpaceStyle.symbols[index % SpaceStyle.symbols.count],
                               colorHex: incoming.colorHex ?? SpaceStyle.palette[index % SpaceStyle.palette.count])
                state.spaces.append(target)
                counts.spaces += 1
            }
            counts.pins += merge(incoming.pinned.compactMap { item($0, pinned: true) }, into: &target.pinned)
            counts.tabs += merge(incoming.tabs.compactMap { item($0, pinned: false) }, into: &target.today)
        }
        if untouched, counts.spaces > 0, starting.pinned.isEmpty, starting.today.isEmpty, openTabs.isEmpty {
            state.spaces.removeAll { $0 === starting }
            state.currentSpaceID = state.spaces[0].id
        }
        var open: [SidebarItem] = []
        counts.tabs += merge(openTabs.compactMap { item($0, pinned: false) }, into: &open, skipping: space.allTabs)
        space.today.insert(contentsOf: open, at: 0)
        applySpace()
        store.setNeedsSave()
        return counts
    }

    /// Adds `incoming` to `items` the way a second import of the same browser should: a tab whose address is
    /// already there (or in `skipping`) is left out, a folder of the same name takes the new children.
    /// Returns how many tabs were added.
    private func merge(_ incoming: [SidebarItem], into items: inout [SidebarItem], skipping: [SidebarItem] = []) -> Int {
        var known = Set((items.flatMap(\.allTabs) + skipping).map { $0.pinnedURL ?? $0.url })
        var added = 0
        for item in incoming {
            if item.isFolder {
                if let folder = items.first(where: { $0.isFolder && $0.title == item.title }) {
                    added += merge(item.children, into: &folder.children)
                } else {
                    item.children.removeAll { !$0.isFolder && !known.insert($0.pinnedURL ?? $0.url).inserted }
                    added += item.allTabs.count
                    items.append(item)
                }
            } else if known.insert(item.pinnedURL ?? item.url).inserted {
                items.append(item)
                added += 1
            }
        }
        return added
    }

    // MARK: our own activations

    /// The tab we just made active (nil: we just closed or switched away), and until when Chrome's own
    /// activation notices count as echoes of that.
    private var ownActivation: (tab: ArdiaCoreTab?, until: Date)?

    private func expectActivation(of tab: ArdiaCoreTab?) {
        ownActivation = (tab ?? ownActivation?.tab, Date().addingTimeInterval(1.5))
    }

    private func unloadTab(_ item: SidebarItem) {
        expectActivation(of: activeTab === runtime.liveTab(for: item) ? nil : activeTab)
        runtime.unload(item)
    }

    // MARK: recently closed

    private struct ClosedTab {
        let url: String
        let title: String
        let spaceID: UUID
    }

    private var closedTabs: [ClosedTab] = []

    private func remember(_ item: SidebarItem) {
        guard !item.url.isEmpty, item.url != "about:blank", let owner = state.space(containing: item) else { return }
        closedTabs.append(ClosedTab(url: item.url, title: item.title, spaceID: owner.id))
        if closedTabs.count > 50 { closedTabs.removeFirst(closedTabs.count - 50) }
    }

    var closedCount: Int { closedTabs.count }

    func reopenClosedTab() {
        guard let last = closedTabs.popLast() else { return }
        if let owner = state.spaces.first(where: { $0.id == last.spaceID }), owner !== space { switchSpace(to: owner) }
        let item = SidebarItem(tab: last.url, title: last.title)
        space.today.insert(item, at: 0)
        sidebar.reload()
        select(item, cause: "reopen-closed")
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

    func toggleSidebar() {
        if state.sidebarHidden, overlayShown {
            state.sidebarHidden = false
            overlayShown = false
        } else {
            state.sidebarHidden.toggle()
            overlayShown = false
        }
        applySidebarMode(animated: true)
        store.setNeedsSave()
    }

    func showCommandBar(editing: Bool) {
        let sidebarVisible = !state.sidebarHidden || overlayShown
        let anchor = editing && sidebarVisible && !contentFullscreen
            ? root.convert(sidebar.addressAnchor.bounds, from: sidebar.addressAnchor) : nil
        if anchor == nil, overlayShown { setOverlay(false) }
        commandBar.show(in: root, editing: editing, current: editing ? (activeTab?.url ?? activeItem?.url) : nil, anchor: anchor)
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

    func restyle(_ target: Space, color: String?, symbol: String?) {
        if let color { target.colorHex = color }
        if let symbol { target.symbol = symbol }
        if target === space { applyTheme(of: target) }
        sidebar.reload()
        store.setNeedsSave()
    }

    /// The space's colour, its strength and its light or dark window. The sidebar's text follows how light
    /// the tinted background really is, so it stays readable on a pale mint as on a deep purple.
    private func applyTheme(of target: Space) {
        let tint = NSColor(hex: target.colorHex)
        let strength = CGFloat(target.tintStrength ?? Double(Theme.tintAlpha))
        root.tintStrength = strength
        sidebar.tintStrength = strength
        root.tint = tint
        sidebar.tint = tint
        // On our root view, not the window: Chrome owns the window and applies its appearance on its own schedule.
        let dark: Bool
        switch target.appearance ?? .system {
        case .system:
            root.appearance = nil
            if !isPrivate { NSApp.appearance = nil }
            dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        case .light:
            root.appearance = NSAppearance(named: .aqua)
            if !isPrivate { NSApp.appearance = NSAppearance(named: .aqua) }
            dark = false
        case .dark:
            root.appearance = NSAppearance(named: .darkAqua)
            // A private window is always dark; it leaves the app's (and the main window's pages') look alone.
            if !isPrivate { NSApp.appearance = NSAppearance(named: .darkAqua) }
            dark = true
        }
        // Chromium follows the app's appearance for pages' prefers-color-scheme, so sites switch with the space.
        let background = Theme.sidebarLuminance(dark: dark, tint: tint, strength: strength)
        sidebar.appearance = NSAppearance(named: background > 0.5 ? .aqua : .darkAqua)
    }

    func editTheme(_ target: Space, from view: NSView) {
        let current = ThemeEditor.Theme(color: NSColor(hex: target.colorHex),
                                        strength: CGFloat(target.tintStrength ?? Double(Theme.tintAlpha)),
                                        appearance: target.appearance ?? .system)
        let editor = ThemeEditor(theme: current) { [weak self] theme in
            guard let self else { return }
            target.colorHex = theme.color.hexString
            target.tintStrength = Double(theme.strength)
            target.appearance = theme.appearance == .system ? nil : theme.appearance
            if target === space { applyTheme(of: target) }
            sidebar.reload()
            store.setNeedsSave()
        }
        editor.present(relativeTo: view.bounds, of: view, edge: .maxX)
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

    func delete(_ target: Space) {
        guard state.spaces.count > 1 else { return }
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

    func move(_ item: SidebarItem, to target: Space) {
        guard let from = state.space(containing: item), from !== target else { return }
        let wasActive = item === activeItem
        from.remove(item)
        if item.pinnedURL != nil { target.pinned.append(item) } else { target.today.insert(item, at: 0) }
        if wasActive {
            from.selectedID = nil
            show(nil)
        }
        sidebar.reload()
        store.setNeedsSave()
    }

    // MARK: SidebarViewDelegate

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

    func remove(_ item: SidebarItem) {
        let wasActive = item === activeItem
        remember(item)
        unloadTab(item)
        space.remove(item)
        if wasActive {
            space.selectedID = nil
            show(nil)
        }
        sidebar.reload()
        store.setNeedsSave()
    }
    func sidebarClearableCount() -> Int { clearableTabs.count }
    func sidebarClosedCount() -> Int { closedCount }
    func sidebarReopenClosed() { reopenClosedTab() }
    func sidebarEditTheme(_ target: Space, from view: NSView) { editTheme(target, from: view) }
    func sidebarManageSpaces() { SettingsWindowController.shared.show(section: .spaces) }
    func sidebarRestyle(_ target: Space, color: String?, symbol: String?) { restyle(target, color: color, symbol: symbol) }
    func sidebarChanged() { store.setNeedsSave() }
    func sidebarExtensions(from view: NSView) { extensions.showMenu(from: view) }

    // MARK: downloads

    private var downloadsObserver: UUID?
    private weak var downloadsPopover: NSPopover?

    func sidebarDownloads(from view: NSView) { toggleDownloads() }

    /// ⇧⌘J and the sidebar's button: the downloads list in a popover off the button (or the address, before any
    /// download has shown the button).
    func toggleDownloads() {
        if let open = downloadsPopover, open.isShown { return open.performClose(nil) }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = DownloadsPanel(isPrivate: isPrivate) { [weak self] url in self?.openInNewTab(url) }
        if sidebarTakesPress(at: sidebar.convert(NSPoint(x: sidebar.bounds.midX, y: sidebar.bounds.midY), to: nil)) {
            let anchor: NSView = sidebar.downloadsButton.isHidden ? sidebar.addressAnchor : sidebar.downloadsButton
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: anchor === sidebar.downloadsButton ? .maxY : .maxX)
        } else {
            // With the sidebar away the list hangs from the page's top left corner.
            popover.show(relativeTo: NSRect(x: 24, y: content.bounds.maxY - 8, width: 1, height: 1), of: content, preferredEdge: .minY)
        }
        downloadsPopover = popover
        showDownloadsState()
    }

    private func observeDownloads() {
        downloadsObserver = Downloads.shared.observe { [weak self] in self?.showDownloadsState() }
        showDownloadsState()
    }

    private func showDownloadsState() {
        let mine = Downloads.shared.items.filter { $0.offTheRecord == isPrivate }
        let active = mine.filter(\.active)
        var progress: Double?
        if !active.isEmpty {
            let total = active.reduce(0) { $0 + max(0, $1.total) }
            progress = active.contains { $0.total <= 0 } || total <= 0 ? -1 : active.reduce(0) { $0 + $1.received } / total
        }
        sidebar.showDownloads(visible: !mine.isEmpty, progress: progress, unseen: Downloads.shared.unseen && downloadsPopover?.isShown != true)
    }

    func sidebarResetPin(_ item: SidebarItem) {
        guard let home = item.pinnedURL else { return }
        item.url = home
        runtime.liveTab(for: item)?.loadURL(home)
        sidebar.reloadItem(item)
        store.setNeedsSave()
    }

    func sidebarDeleteFolder(_ folder: SidebarItem) {
        guard let loc = space.location(of: folder) else { return }
        space.remove(folder)
        if let parent = loc.parent { parent.children.insert(contentsOf: folder.children, at: loc.index) }
        else { space.pinned.insert(contentsOf: folder.children, at: loc.index) }
        sidebar.reload()
        store.setNeedsSave()
    }

    func sidebarFavicon(for item: SidebarItem) -> NSImage? {
        if let image = runtime.liveTab(for: item)?.favicon { return image }
        return store.favicon(for: item)
    }

    func sidebarIsLoaded(_ item: SidebarItem) -> Bool {
        guard let tab = runtime.liveTab(for: item) else { return false }
        return !tab.discarded
    }

    func sidebarIsLoading(_ item: SidebarItem) -> Bool {
        runtime.liveTab(for: item)?.loading ?? false
    }

    // MARK: TabRuntimeDelegate

    func runtime(_ runtime: TabRuntime, loadingOf tab: ArdiaCoreTab) {
        guard tab === shownTab else { return }
        placeLoadingBar()
        loadingBar.show(loading: tab.loading, progress: tab.progress)
    }

    func runtime(_ runtime: TabRuntime, didUpdate item: SidebarItem) {
        if let tab = runtime.liveTab(for: item), let icon = tab.favicon { store.setFavicon(icon, for: item) }
        sidebar.reloadItem(item)
        if item === activeItem { sidebar.updateAddress(runtime.liveTab(for: item)) }
        store.setNeedsSave()
    }

    func runtime(_ runtime: TabRuntime, adopt tab: ArdiaCoreTab, opener: ArdiaCoreTab?, foreground: Bool) {
        let item = SidebarItem(tab: tab.url, title: tab.title)
        let owner = opener.flatMap { runtime.item(for: $0) }.flatMap { state.space(containing: $0) } ?? space
        owner.today.insert(item, at: 0)
        runtime.bind(tab, to: item)
        if owner === space { sidebar.reload() }
        if foreground { select(item, cause: "chrome-new-tab") } else { tab.view.isHidden = true }
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
            owner.selectedID = nil
            show(nil)
            if let next = owner.today.first(where: { runtime.liveTab(for: $0) != nil }) { select(next, cause: "tab-closed-neighbor") }
        }
        sidebar.reload()
        store.setNeedsSave()
    }

    func runtime(_ runtime: TabRuntime, tab: ArdiaCoreTab, didFindMatches count: Int32, active: Int32) {
        findBar.update(count: Int(count), active: Int(active))
    }

    func runtime(_ runtime: TabRuntime, tabNeedsActivation tab: ArdiaCoreTab) {
        if let item = runtime.item(for: tab), item !== activeItem { select(item, cause: "tab-requests-activation") }
    }

    // MARK: ArdiaCoreWindowDelegate

    @objc(window:didInsertTab:opener:disposition:)
    func window(_ window: ArdiaCoreWindow, didInsert tab: ArdiaCoreTab, opener: ArdiaCoreTab?, disposition: String) {
        guard !runtime.isMine(tab) else { return }
        runtime(runtime, adopt: tab, opener: opener, foreground: disposition != "new_background_tab")
    }

    @objc(window:didActivateTab:)
    func window(_ window: ArdiaCoreWindow, didActivate tab: ArdiaCoreTab) {
        // Chrome's tab strip also activates tabs as a side effect of what we do (closing the active tab picks a
        // neighbour, opening one shuffles the strip). Those echoes don't get to change the model's active tab.
        if let own = ownActivation, Date() < own.until {
            if let expected = own.tab, expected !== tab, !expected.closed {
                Trace.log("ignored chrome activation of \"\(runtime.item(for: tab)?.displayTitle ?? "?")\" (echo of our own change)")
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
        let state = prompt["state"] as? String ?? ""
        guard state == "save" || state == "update" else { return }
        let origin = prompt["origin"] as? String ?? ""
        let update = state == "update"
        let decline = update ? "nope" : "dismiss"
        var buttons: [PromptCard.Button] = []
        if !update {
            buttons.append(.init(title: L("password.never"), style: .plain) { [weak tab] _ in
                tab?.resolvePasswordPrompt("never", username: nil, password: nil)
            })
        }
        buttons.append(.init(title: L("password.notNow"), style: .secondary) { [weak tab] _ in
            tab?.resolvePasswordPrompt(decline, username: nil, password: nil)
        })
        buttons.append(.init(title: update ? L("password.update") : L("password.save"), style: .primary) { [weak tab] values in
            let username = values.first.flatMap { $0.isEmpty ? nil : $0 }
            tab?.resolvePasswordPrompt(update ? "update" : "save", username: username, password: nil)
        })
        sitePrompts.add(.init(id: "password-\(tab.tabId)", tab: tab, belongsToTab: true, icon: tab.favicon,
                              host: URL(string: origin)?.host ?? origin,
                              title: update ? L("password.update.title") : L("password.save.title"),
                              fields: [.init(placeholder: L("password.username"), value: prompt["username"] as? String ?? "", secure: false)],
                              buttons: buttons,
                              dismissed: { [weak tab] in tab?.resolvePasswordPrompt(decline, username: nil, password: nil) }))
    }

    @objc(windowShouldClose:)
    func windowShouldClose(_ window: ArdiaCoreWindow) -> Bool {
        if isPrivate {
            // Closing a private window ends it: its tabs, and with them the off-the-record profile, go away.
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

    // MARK: engine prompts

    func showPermissionRequest(_ request: [String: Any], tab: ArdiaCoreTab) {
        let id = request["id"] as? String ?? ""
        let origin = request["origin"] as? String ?? ""
        let kinds = (request["permissions"] as? [String] ?? []).map(Prompts.permissionName).joined(separator: ", ")
        let resolve = { (result: String, remember: Bool) in
            ArdiaCoreEngine.shared?.resolvePermission(id, result: result, remember: remember)
        }
        sitePrompts.add(.init(id: id, tab: tab, belongsToTab: true, icon: tab.favicon, host: URL(string: origin)?.host ?? origin,
                              title: L("permission.wants", kinds), buttons: [
                                  .init(title: L("permission.deny"), style: .plain) { _ in resolve("deny", true) },
                                  .init(title: L("permission.once"), style: .secondary) { _ in resolve("accept", false) },
                                  .init(title: L("permission.allow"), style: .primary) { _ in resolve("accept", true) },
                              ], dismissed: { resolve("dismiss", false) }))
    }

    func runtime(_ runtime: TabRuntime, tab: ArdiaCoreTab, asksToOpenApp request: [String: Any]) {
        let id = request["id"] as? String ?? ""
        let origin = request["origin"] as? String
        let host = origin.flatMap { URL(string: $0)?.host } ?? origin ?? tab.committedOrigin ?? ""
        let resolve = { (open: Bool, remember: Bool) in ArdiaCoreEngine.resolveExternalApp(id, open: open, remember: remember) }
        guard let app = request["app"] as? String else {
            // Nothing on this Mac opens the link's kind.
            let scheme = request["scheme"] as? String ?? ""
            sitePrompts.add(.init(id: "app-\(id)", tab: tab, belongsToTab: true, icon: tab.favicon, host: host,
                                  title: L("externalApp.none", scheme), buttons: [.init(title: "OK", style: .primary) { _ in resolve(false, false) }],
                                  dismissed: { resolve(false, false) }))
            return
        }
        // The app's own icon: from its bundle, else the picture the engine sends along.
        let icon = (request["appPath"] as? String).map { NSWorkspace.shared.icon(forFile: $0) }
            ?? (request["icon"] as? String).flatMap { $0.components(separatedBy: ",").last }.flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:))
            ?? tab.favicon
        let name = (app as NSString).deletingPathExtension
        var buttons: [PromptCard.Button] = [.init(title: L("common.cancel"), style: .plain) { _ in resolve(false, false) }]
        // "Always" only where the engine can remember it (a page with an origin).
        if !(request["remember"] is NSNull), request["remember"] != nil {
            buttons.append(.init(title: L("externalApp.always"), style: .secondary) { _ in resolve(true, true) })
        }
        buttons.append(.init(title: L("externalApp.open"), style: .primary) { _ in resolve(true, false) })
        sitePrompts.add(.init(id: "app-\(id)", tab: tab, belongsToTab: true, icon: icon, host: host,
                              title: L("externalApp.title", name), buttons: buttons, dismissed: { resolve(false, false) }))
    }

    /// A line of text from the user (a space's name), as a card instead of a modal alert.
    func ask(_ title: String, placeholder: String, value: String = "", confirm: String, completion: @escaping (String) -> Void) {
        showWindow()
        sitePrompts.add(.init(id: "ask-\(title)", tab: nil, belongsToTab: false, icon: IconChoice.preview(IconChoice.current),
                              host: L("app.name"), title: title, fields: [.init(placeholder: placeholder, value: value, secure: false)],
                              focusesField: true, buttons: [
                                  .init(title: L("common.cancel"), style: .secondary) { _ in },
                                  .init(title: confirm, style: .primary) { values in
                                      let text = values.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                      if !text.isEmpty { completion(text) }
                                  },
                              ], dismissed: {}))
    }

    /// A yes-or-no about a site (clearing its data, say), on the site's own card.
    func confirm(host: String, icon: NSImage?, title: String, detail: String?, confirm: String, action: @escaping () -> Void) {
        sitePrompts.add(.init(id: "confirm-\(title)", tab: nil, belongsToTab: false, icon: icon, host: host, title: title, detail: detail,
                              buttons: [.init(title: L("common.cancel"), style: .secondary) { _ in },
                                        .init(title: confirm, style: .primary) { _ in action() }],
                              dismissed: {}))
    }

    /// A short message from the app itself (an update check, say), as a card instead of an alert.
    func showNotice(_ title: String, detail: String?) {
        showWindow()
        sitePrompts.add(.init(id: "notice-\(title)", tab: nil, belongsToTab: false, icon: IconChoice.preview(IconChoice.current),
                              host: L("app.name"), title: title, detail: detail,
                              buttons: [.init(title: "OK", style: .primary) { _ in }], dismissed: {}))
    }

    func dismissPermissionRequest(_ id: String) {
        sitePrompts.remove(id: id)
    }

    func showExtensionInstallPrompt(_ prompt: [String: Any]) {
        let id = prompt["requestId"] as? String ?? ""
        let name = prompt["name"] as? String ?? L("extensions.unnamed")
        let permissions = prompt["permissions"] as? [String] ?? []
        let detail = permissions.isEmpty ? nil : L("extensions.install.can") + "\n• " + permissions.prefix(6).joined(separator: "\n• ")
        let icon = prompt["icon"] as? NSImage ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
        sitePrompts.add(.init(id: "install-\(id)", tab: nil, belongsToTab: false, icon: icon, host: L("extensions.install.source"),
                              title: L("extensions.install.title", name), detail: detail, buttons: [
                                  .init(title: L("common.cancel"), style: .secondary) { _ in
                                      ArdiaCoreEngine.resolveExtensionInstallPrompt(id, accepted: false)
                                  },
                                  .init(title: L("extensions.install"), style: .primary) { _ in
                                      ArdiaCoreEngine.resolveExtensionInstallPrompt(id, accepted: true)
                                  },
                              ], dismissed: { ArdiaCoreEngine.resolveExtensionInstallPrompt(id, accepted: false) }))
    }
}

#if DRIFT_DEV
extension BrowserWindowController {
    func debugSetOverlay(_ shown: Bool) { setOverlay(shown) }
    func debugType(_ text: String) { commandBar.debugType(text) }
    func debugHideCommandBar() { commandBar.hide() }
    func debugCommitRename(_ title: String) -> Bool { sidebar.debugCommitRename(title) }
    func debugReloadSidebar() { sidebar.reload() }
    func debugToggle(_ folder: SidebarItem) { sidebar.toggleFolder(folder) }
    var debugSidebar: SidebarView { sidebar }
    var debugCommandBar: CommandBar { commandBar }
    func debugSwipe(_ event: NSEvent) -> Bool { swipeSpaces(event, at: NSPoint(x: sidebar.frame.midX, y: sidebar.frame.midY)) }
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

/// The page is loading: a short capsule in the window's frame above the page, Arc-style — a dim track with a
/// light segment sliding back and forth along it — that fades out once the page is done. Its colours follow the
/// frame's light or dark look.
final class LoadingBar: NSView {
    static let size = NSSize(width: 140, height: 4)
    private let track = CALayer()
    private let glow = CALayer()
    private var visible = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        track.cornerRadius = Self.size.height / 2
        track.masksToBounds = true
        glow.cornerRadius = Self.size.height / 2
        track.addSublayer(glow)
        layer?.addSublayer(track)
        alphaValue = 0
        recolor()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolor()
    }

    private func recolor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.backgroundColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
            glow.backgroundColor = NSColor.labelColor.withAlphaComponent(0.55).cgColor
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        glow.frame = NSRect(x: 0, y: 0, width: bounds.width * 0.4, height: bounds.height)
        CATransaction.commit()
    }

    func show(loading: Bool, progress: Double, animated: Bool = true) {
        superview?.addSubview(self, positioned: .above, relativeTo: nil)
        guard loading != visible else { return }
        visible = loading
        if loading {
            recolor()
            needsLayout = true
            layoutSubtreeIfNeeded()
            let slide = CABasicAnimation(keyPath: "position.x")
            slide.fromValue = -Self.size.width * 0.2
            slide.toValue = Self.size.width * 1.2
            slide.duration = 0.9
            slide.autoreverses = true
            slide.repeatCount = .infinity
            slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glow.add(slide, forKey: "slide")
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animated ? (loading ? 0.15 : 0.35) : 0
            animator().alphaValue = loading ? 1 : 0
        }, completionHandler: { [weak self] in
            if self?.visible == false { self?.glow.removeAnimation(forKey: "slide") }
        })
    }
}

/// A minimised window in the Dock: its picture, scaled to fit, with the app's chosen icon in the corner.
final class MiniaturizedTile: NSView {
    var snapshot: NSImage?
    var badge: NSImage?

    override func draw(_ dirtyRect: NSRect) {
        if let snapshot, snapshot.size.width > 0 {
            let scale = min(bounds.width / snapshot.size.width, bounds.height / snapshot.size.height)
            let size = NSSize(width: snapshot.size.width * scale, height: snapshot.size.height * scale)
            snapshot.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
        }
        let side = bounds.width * 0.42
        badge?.draw(in: NSRect(x: bounds.maxX - side, y: 0, width: side, height: side))
    }
}

