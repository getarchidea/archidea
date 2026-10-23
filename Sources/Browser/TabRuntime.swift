import AppKit

protocol TabRuntimeDelegate: AnyObject {
    func runtime(_ runtime: TabRuntime, didUpdate item: SidebarItem)
    func runtime(_ runtime: TabRuntime, adopt tab: ArdiaCoreTab, opener: ArdiaCoreTab?, foreground: Bool)
    func runtime(_ runtime: TabRuntime, tabDidClose item: SidebarItem)
    func runtime(_ runtime: TabRuntime, tab: ArdiaCoreTab, didFindMatches count: Int32, active: Int32)
    func runtime(_ runtime: TabRuntime, tabNeedsActivation tab: ArdiaCoreTab)
    func runtime(_ runtime: TabRuntime, loadingOf tab: ArdiaCoreTab)
}

/// Owns the live Chrome tabs. A sidebar item gets a tab only when it is opened.
final class TabRuntime: NSObject, ArdiaCoreTabDelegate {
    /// Background tabs untouched this long are discarded; 0 never discards.
    var unloadMinutes = 30

    let coreWindow: ArdiaCoreWindow
    let profile: ArdiaCoreProfile
    weak var delegate: TabRuntimeDelegate?

    private var tabs: [UUID: ArdiaCoreTab] = [:]
    private var items: [ObjectIdentifier: SidebarItem] = [:]
    private var creating = false
    private var sleepTimer: Timer?

    init(coreWindow: ArdiaCoreWindow, profile: ArdiaCoreProfile) {
        self.coreWindow = coreWindow
        self.profile = profile
        super.init()
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.discardIdleTabs() }
    }

    func liveTab(for item: SidebarItem) -> ArdiaCoreTab? {
        guard let tab = tabs[item.id], !tab.closed else { return nil }
        return tab
    }

    func item(for tab: ArdiaCoreTab) -> SidebarItem? {
        items[ObjectIdentifier(tab)]
    }

    func isMine(_ tab: ArdiaCoreTab) -> Bool {
        creating || items[ObjectIdentifier(tab)] != nil
    }

    func ensureTab(for item: SidebarItem) -> ArdiaCoreTab {
        if let tab = liveTab(for: item) { return tab }
        creating = true
        let tab = coreWindow.openTab(item.url.isEmpty ? "about:blank" : item.url, profile: profile, foreground: false)
        creating = false
        bind(tab, to: item)
        return tab
    }

    func bind(_ tab: ArdiaCoreTab, to item: SidebarItem) {
        tabs[item.id] = tab
        items[ObjectIdentifier(tab)] = item
        tab.delegate = self
    }

    /// Closes the Chrome tab; the sidebar item itself is the caller's business.
    func unload(_ item: SidebarItem) {
        guard let tab = tabs.removeValue(forKey: item.id) else { return }
        items.removeValue(forKey: ObjectIdentifier(tab))
        tab.view.removeFromSuperview()
        if !tab.closed { tab.close() }
    }

    func forget(_ tab: ArdiaCoreTab) {
        guard let item = items.removeValue(forKey: ObjectIdentifier(tab)) else { return }
        tabs.removeValue(forKey: item.id)
        tab.view.removeFromSuperview()
    }

    var liveCount: Int { tabs.count }

    private func discardIdleTabs() {
        guard unloadMinutes > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(unloadMinutes) * 60)
        for (_, tab) in tabs where !tab.closed && !tab.discarded && !tab.audible {
            guard let item = item(for: tab), item.lastActive < cutoff, tab.view.isHidden else { continue }
            tab.discard()
        }
    }

    // MARK: ArdiaCoreTabDelegate

    private func changed(_ tab: ArdiaCoreTab, _ update: (SidebarItem) -> Void = { _ in }) {
        guard let item = item(for: tab) else { return }
        update(item)
        delegate?.runtime(self, didUpdate: item)
    }

    @objc(tabDidChangeTitle:) func tabDidChangeTitle(_ tab: ArdiaCoreTab) {
        changed(tab) { item in if !tab.title.isEmpty, item.pinnedURL == nil || item.title.isEmpty { item.title = tab.title } }
    }

    @objc(tabDidChangeURL:) func tabDidChangeURL(_ tab: ArdiaCoreTab) {
        changed(tab) { item in if !tab.url.isEmpty { item.url = tab.url } }
    }

    @objc(tabDidChangeFavicon:) func tabDidChangeFavicon(_ tab: ArdiaCoreTab) { changed(tab) }
    @objc(tabDidChangeLoading:) func tabDidChangeLoading(_ tab: ArdiaCoreTab) {
        changed(tab)
        delegate?.runtime(self, loadingOf: tab)
    }
    @objc(tabDidChangeProgress:) func tabDidChangeProgress(_ tab: ArdiaCoreTab) { delegate?.runtime(self, loadingOf: tab) }
    @objc(tabDidChangeNavigationState:) func tabDidChangeNavigationState(_ tab: ArdiaCoreTab) { changed(tab) }
    @objc(tabDidChangeAudio:) func tabDidChangeAudio(_ tab: ArdiaCoreTab) { changed(tab) }
    @objc(tabDidChangeDiscarded:) func tabDidChangeDiscarded(_ tab: ArdiaCoreTab) { changed(tab) }

    // MARK: blocked requests

    private var blocked: [ObjectIdentifier: Int] = [:]

    /// Requests the blocker stopped on the tab's current page.
    func blockedCount(for tab: ArdiaCoreTab) -> Int { blocked[ObjectIdentifier(tab)] ?? 0 }

    @objc(tab:didBlockRequests:lastURL:)
    func tab(_ tab: ArdiaCoreTab, didBlockRequests count: Int32, lastURL url: String) {
        blocked[ObjectIdentifier(tab)] = Int(count)
    }

    @objc(tabDidCommitDocument:) func tabDidCommitDocument(_ tab: ArdiaCoreTab) {
        blocked[ObjectIdentifier(tab)] = nil
    }

    @objc(tabWillClose:) func tabWillClose(_ tab: ArdiaCoreTab) {
        blocked[ObjectIdentifier(tab)] = nil
        guard let item = item(for: tab) else { return }
        forget(tab)
        delegate?.runtime(self, tabDidClose: item)
    }

    @objc(tab:didFindMatches:active:final:)
    func tab(_ tab: ArdiaCoreTab, didFindMatches count: Int32, active: Int32, final: Bool) {
        delegate?.runtime(self, tab: tab, didFindMatches: count, active: active)
    }

    @objc(tab:requestsActivation:)
    func tab(_ tab: ArdiaCoreTab, requestsActivation reason: String) {
        delegate?.runtime(self, tabNeedsActivation: tab)
    }
}
