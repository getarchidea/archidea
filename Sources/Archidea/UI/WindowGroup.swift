import AppKit
import ArchideaCore
import ArdiaCore

/// The browser windows that show one sidebar: all the normal windows share the saved one, and a private window has a
/// group of its own. Each window shows its own space and tab (`WindowState`) and holds its own live pages; a page is
/// open in one window at a time. The group is where the windows find each other: to show a change to the sidebar in
/// all of them, to hand a page from one to another, and to close an item's page wherever it is open.
final class WindowGroup {
    let store: Store
    /// In the order they were opened.
    private(set) var windows: [BrowserWindowController] = []
    /// The window used last: links from other apps, the Dock and the app's notices go there.
    private(set) weak var front: BrowserWindowController?
    private var archiveTimer: Timer?
    /// Windows due to show a change made in another one, on the next pass of the run loop.
    private var behind: Set<ObjectIdentifier> = []
    /// The live folders' feeds, read for the normal windows' sidebar; a private window's group never starts it.
    private(set) lazy var liveFolders = LiveFolders(group: self)

    init(store: Store) {
        self.store = store
        archiveTimer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { [weak self] _ in self?.archiveStaleToday() }
    }

    func add(_ window: BrowserWindowController) {
        windows.append(window)
        if front == nil { front = window }
    }

    func remove(_ window: BrowserWindowController) {
        windows.removeAll { $0 === window }
        if front === window { front = windows.last }
        if windows.isEmpty {
            archiveTimer?.invalidate()
            archiveTimer = nil
        }
    }

    func noteFront(_ window: BrowserWindowController) { front = window }

    // MARK: live pages

    /// The window `item`'s page is open in, if it's open.
    func window(holding item: SidebarItem) -> BrowserWindowController? {
        windows.first { $0.runtime.liveTab(for: item) != nil }
    }

    func liveTab(for item: SidebarItem) -> ArdiaCoreTab? {
        window(holding: item)?.runtime.liveTab(for: item)
    }

    /// Brings `item`'s open page into `target` from the window that has it.
    func take(_ item: SidebarItem, into target: BrowserWindowController) {
        guard let source = window(holding: item), source !== target, let tab = source.giveUp(item) else { return }
        target.receive(tab, for: item)
    }

    /// `item` is going (closed, archived, its space deleted) or only its page is: the page closes in whichever window
    /// has it, and windows that had it in front show nothing in its place.
    func unload(_ item: SidebarItem) {
        for tab in item.allTabs { windows.forEach { $0.unloadOwn(tab) } }
    }

    /// `origin` stopped showing `item`: a window waiting for that page takes it.
    func letGo(_ item: SidebarItem, by origin: BrowserWindowController) {
        DispatchQueue.main.async { [weak self] in
            for window in self?.windows ?? [] where window !== origin && window.waitsFor(item) { window.refreshFront() }
        }
    }

    // MARK: showing changes

    /// The shared sidebar changed in `origin` (nil: in none of them): the other windows show it once this pass of the
    /// run loop is over, however many changes it made.
    func sidebarChanged(by origin: BrowserWindowController?) {
        for window in windows where window !== origin {
            let key = ObjectIdentifier(window)
            guard behind.insert(key).inserted else { continue }
            DispatchQueue.main.async { [weak self, weak window] in
                self?.behind.remove(key)
                window?.catchUp()
            }
        }
    }

    /// A row changed (its title, its icon, its page loading): every other window that lists it redraws it.
    func itemChanged(_ item: SidebarItem, by origin: BrowserWindowController, folders: Bool = false) {
        for window in windows where window !== origin { window.sidebar.reloadItem(item, folders: folders) }
    }

    // MARK: archiving

    /// Today tabs untouched for the archive time go while the browser runs too, not only at the next launch: all but
    /// those a window has in front and those playing sound. They're on ⇧⌘T like any closed tab.
    func archiveStaleToday() {
        guard let hours = windows.first?.settings.archiveHours, hours > 0 else { return }
        let state = store.state
        let cutoff = Date().addingTimeInterval(-Double(hours) * 60 * 60)
        var archived = 0
        for owner in state.spaces {
            let stale = owner.staleToday(before: cutoff) { item in
                state.isInFront(item, in: owner) || item.allTabs.contains { self.liveTab(for: $0)?.audible == true }
            }
            for item in stale {
                state.remember(item)
                unload(item)
                owner.remove(item)
                archived += 1
            }
        }
        guard archived > 0 else { return }
        Trace.log("archived \(archived) Today tabs untouched for \(hours) h")
        sidebarChanged(by: nil)
        store.setNeedsSave()
    }
}
