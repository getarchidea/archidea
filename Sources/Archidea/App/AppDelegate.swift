import AppKit
import ArchideaCore
import ArdiaCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    private(set) var windowController: BrowserWindowController?
    /// Open private windows; each has its own off-the-record profile.
    private var privateWindows: [BrowserWindowController] = []
    /// Mini windows holding links from other apps.
    private var miniWindows: [MiniWindowController] = []

    #if DRIFT_DEV
    var debugMiniWindows: [MiniWindowController] { miniWindows }
    #endif

    /// The mini window in front, when it is: page commands (reload, back, ⌘W…) go to its page.
    private var keyMini: MiniWindowController? { miniWindows.first { $0.window.isKeyWindow } }

    /// The browser window commands go to: the key one, else the main window.
    var current: BrowserWindowController? {
        privateWindows.first { $0.window.isKeyWindow || $0.window.isMainWindow } ?? windowController
    }

    /// The window a tab lives in, for the engine's requests about it.
    func controller(for tab: ArdiaCoreTab) -> BrowserWindowController? {
        privateWindows.first { $0.owns(tab) } ?? windowController
    }

    /// A permission request for a page in a mini window goes to that window's card; false when it's not one.
    func miniWindowShowsPermissionRequest(_ request: [String: Any], tab: ArdiaCoreTab) -> Bool {
        guard let mini = miniWindows.first(where: { $0.tab === tab }) else { return false }
        mini.showPermissionRequest(request, tab: tab)
        return true
    }

    /// The window holding `profile`'s tabs when the engine opens a new one there (a link, a popup).
    func controller(for profile: ArdiaCoreProfile) -> BrowserWindowController? {
        privateWindows.first { $0.profile === profile } ?? windowController
    }

    @objc func newPrivateWindow(_ sender: Any?) {
        guard let engine = ArdiaCoreEngine.shared else { return }
        engine.offTheRecordProfile(for: engine.defaultProfile) { [weak self] profile, error in
            guard let self, let profile else { return Trace.log("private window: \(error ?? "no profile")") }
            let controller = BrowserWindowController(store: Store(ephemeral: .privateWindow()), profile: profile, preferences: store)
            privateWindows.append(controller)
            controller.showWindow()
        }
    }

    func privateDismiss(_ requestId: String) {
        privateWindows.forEach { $0.dismissPermissionRequest(requestId) }
        miniWindows.forEach { $0.dismissPermissionRequest(requestId) }
    }

    func privateWindowClosed(_ controller: BrowserWindowController) {
        privateWindows.removeAll { $0 === controller }
    }

    /// The browser-wide settings changed: every window takes them up.
    func settingsChanged() {
        windowController?.settingsChanged()
        privateWindows.forEach { $0.settingsChanged() }
    }

    func start() {
        guard let engine = ArdiaCoreEngine.shared else { return }
        NSApp.setActivationPolicy(.regular)
        IconChoice.apply()
        installDisplayPass()
        Updater.shared.start()
        Downloads.shared.start(profile: engine.defaultProfile)
        Favicons.shared.profile = engine.defaultProfile
        NSApp.mainMenu = Shortcuts.buildMainMenu(target: self)
        let controller = BrowserWindowController(store: store, profile: engine.defaultProfile)
        windowController = controller
        if OnboardingWindowController.isNeeded {
            // The first launch is the welcome window alone; the browser comes up once the user is through it.
            OnboardingWindowController.shared.onFinish = { [weak controller] in
                controller?.showWindow()
                NSApp.activate(ignoringOtherApps: true)
            }
            OnboardingWindowController.shared.show()
        } else {
            controller.showWindow()
            NSApp.activate(ignoringOtherApps: true)
        }
        IncomingLinks.handler = { [weak self] url in self?.openIncoming(url) }
        #if DRIFT_DEV
        SelfTest.runIfRequested(controller)
        Demo.runIfRequested(controller)
        Repro.runIfRequested(controller)
        DragRepro.runIfRequested(controller)
        FeatureDemo.runIfRequested(controller)
        TerminateTest.runIfRequested()
        LookDemo.runIfRequested(controller)
        PolishDemo.runIfRequested(controller)
        SiteDemo.runIfRequested(controller)
        ImportDemo.runIfRequested(controller)
        OnboardingDemo.runIfRequested()
        ExtIconsDemo.runIfRequested(controller)
        RefocusDemo.runIfRequested(controller)
        DragHarness.runIfRequested(controller)
        PrivateDemo.runIfRequested(self)
        SwipeDemo.runIfRequested(controller)
        CommandBarDemo.runIfRequested(controller)
        DownloadsDemo.runIfRequested(controller)
        ExternalAppDemo.runIfRequested(controller)
        MinimizeDemo.runIfRequested(controller)
        CardsDemo.runIfRequested(controller)
        RenameDemo.runIfRequested(controller)
        MiniDemo.runIfRequested(self)
        StartDemo.runIfRequested(controller)
        UpdateCheckDemo.runIfRequested(self)
        #endif
    }

    /// With no Chromium window on screen (the first-launch window, everything minimised) the engine's message pump
    /// runs main-queue work without AppKit's display pass after it: views changed from timers and callbacks stayed
    /// stale until the next mouse event. This runs that pass whenever the loop is about to sleep.
    private func installDisplayPass() {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 1_900_000) { _, _ in
            for window in NSApp.windows where window.isVisible && window.viewsNeedDisplay { window.displayIfNeeded() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let welcome = OnboardingWindowController.shared.window, welcome.isVisible, OnboardingWindowController.shared.onFinish != nil {
            welcome.makeKeyAndOrderFront(nil)
            return true
        }
        windowController?.showWindow()
        return true
    }

    /// The Dock icon's menu: a new tab or private window, and the spaces to jump straight into. macOS adds the open
    /// windows above and Options / Quit below.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let controller = windowController, OnboardingWindowController.shared.window?.isVisible != true else { return nil }
        let menu = NSMenu()
        menu.addItem(withTitle: L("menu.newTab"), action: #selector(dockNewTab(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("menu.newPrivateWindow"), action: #selector(newPrivateWindow(_:)), keyEquivalent: "").target = self
        let spaces = controller.state.spaces
        if spaces.count > 1 {
            menu.addItem(.separator())
            for space in spaces {
                let item = menu.addItem(withTitle: space.name, action: #selector(dockOpenSpace(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = space.id
                item.image = Glyphs.image(space.symbol, filled: false, pointSize: 13)
                item.state = space.id == controller.state.currentSpaceID ? .on : .off
            }
        }
        return menu
    }

    @objc private func dockNewTab(_ sender: Any?) {
        windowController?.showWindow()
        NSApp.activate()
        windowController?.showCommandBar(editing: false)
    }

    @objc private func dockOpenSpace(_ sender: NSMenuItem) {
        guard let controller = windowController, let id = sender.representedObject as? UUID,
              let space = controller.state.spaces.first(where: { $0.id == id }) else { return }
        controller.showWindow()
        NSApp.activate()
        controller.switchSpace(to: space)
    }

    /// Links, and files opened with Archidea: a web page, or a saved link (.webloc), which opens the address in it.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL, url.pathExtension.lowercased() == "webloc",
               let data = try? Data(contentsOf: url),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let address = (plist["URL"] as? String).flatMap(URL.init(string:)) {
                IncomingLinks.receive(address)
            } else {
                IncomingLinks.receive(url)
            }
        }
    }

    /// A link from another app: a mini window of its own, or (as Settings say) a new tab in the browser window.
    private func openIncoming(_ url: URL) {
        guard let controller = windowController else { return }
        if OnboardingWindowController.shared.window?.isVisible == true {
            // Mid-welcome the browser isn't up yet; the link waits in a tab for when it is.
            controller.openInNewTab(url.absoluteString)
            return
        }
        if controller.settings.linksInMiniWindow, let engine = ArdiaCoreEngine.shared {
            let mini = MiniWindowController(url: url.absoluteString, profile: engine.defaultProfile,
                                            cascadeFrom: miniWindows.last?.window) { [weak self] closed in
                self?.miniWindows.removeAll { $0 === closed }
            }
            miniWindows.append(mini)
            mini.show()
            return
        }
        controller.showWindow()
        NSApp.activate()
        controller.openInNewTab(url.absoluteString)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Trace.log("app: should terminate")
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        Trace.log("app: will terminate")
        store.saveNow()
    }

    // MARK: menu actions

    @objc func quit(_ sender: Any?) {
        store.saveNow()
        ArdiaCoreEngine.shared?.quit()
    }

    /// The page that page commands act on: the mini window's when it's in front, else the browser window's tab.
    private var activePage: ArdiaCoreTab? { keyMini?.tab ?? current?.activeTab }

    @objc func newTab(_ sender: Any?) { current?.showCommandBar(editing: false) }
    @objc func openLocation(_ sender: Any?) { current?.showCommandBar(editing: true) }
    @objc func closeTab(_ sender: Any?) {
        if let mini = keyMini { return mini.window.performClose(sender) }
        current?.closeSelected()
    }
    @objc func togglePin(_ sender: Any?) { current?.togglePinSelected() }
    @objc func newFolder(_ sender: Any?) { current?.newFolder() }
    @objc func toggleSidebar(_ sender: Any?) { current?.toggleSidebar() }
    @objc func reload(_ sender: Any?) { activePage?.reload() }
    @objc func hardReload(_ sender: Any?) { activePage?.reloadIgnoringCache() }
    @objc func goBack(_ sender: Any?) { activePage?.goBack() }
    @objc func goForward(_ sender: Any?) { activePage?.goForward() }
    @objc func find(_ sender: Any?) { current?.showFind() }
    @objc func copyURL(_ sender: Any?) {
        if let mini = keyMini {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(mini.tab.url, forType: .string)
        } else {
            current?.copyURL()
        }
    }
    @objc func devTools(_ sender: Any?) { current?.toggleDevTools() }
    @objc func zoomIn(_ sender: Any?) { activePage?.zoomStep(1) }
    @objc func zoomOut(_ sender: Any?) { activePage?.zoomStep(-1) }
    @objc func zoomReset(_ sender: Any?) { activePage?.zoomFactor = 1 }
    @objc func nextTab(_ sender: Any?) { current?.selectAdjacent(1) }
    @objc func previousTab(_ sender: Any?) { current?.selectAdjacent(-1) }
    @objc func newSpace(_ sender: Any?) { current?.newSpace() }
    @objc func nextSpace(_ sender: Any?) { current?.switchSpace(by: 1) }
    @objc func previousSpace(_ sender: Any?) { current?.switchSpace(by: -1) }
    @objc func extensionsStore(_ sender: Any?) { current?.openInNewTab("https://chromewebstore.google.com/category/extensions") }
    @objc func passwords(_ sender: Any?) { current?.openInNewTab("chrome://password-manager/passwords") }
    @objc func settings(_ sender: Any?) { SettingsWindowController.shared.show() }

    @objc func saveDiagnostics(_ sender: Any?) {
        guard let file = Trace.save() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    @objc func reportIssue(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/getarchidea/archidea/issues/new/choose")!)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        let updater = Updater.shared
        guard updater.isEnabled else {
            windowController?.showNotice(L("update.notConfigured"), detail: L("update.version", updater.currentVersion))
            return
        }
        if case .ready = updater.state { return installUpdate() }
        updater.checkNow { [weak self] state in
            switch state {
            case .upToDate:
                self?.windowController?.showNotice(L("update.upToDate"), detail: L("update.version", updater.currentVersion))
            case let .failed(reason):
                self?.windowController?.showNotice(L("update.failed"), detail: reason)
            case let .downloading(version):
                self?.windowController?.showNotice(L("update.downloading", version), detail: L("update.downloading.detail"))
            case .ready:
                self?.installUpdate()
            default: break
            }
        }
    }

    /// Restarts into the downloaded update, or says why it can't go in where the app is.
    func installUpdate() {
        guard case .ready = Updater.shared.state, !Updater.shared.installNow() else { return }
        windowController?.showNotice(L("update.cantInstall"), detail: L("update.cantInstall.detail"))
    }
    @objc func reopenClosedTab(_ sender: Any?) { current?.reopenClosedTab() }
    @objc func importData(_ sender: Any?) { ImportWindowController.shared.show() }
    @objc func history(_ sender: Any?) { current?.openInNewTab("chrome://history") }
    @objc func downloads(_ sender: Any?) { current?.toggleDownloads() }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        current?.selectTab(number: sender.tag)
    }
}
