import AppKit
import ArchideaCore

/// Live folders: following a page makes a folder among the pins that fills itself from the site's feed
/// (`LiveFolders` reads them), with what's new marked until it's opened.
extension BrowserWindowController {
    /// A web page can be followed, from a normal window: a private one's sidebar isn't kept, nor read in the background.
    func canFollow(_ address: String) -> Bool {
        guard !isPrivate, let scheme = URL(string: address)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// The feed behind `address` becomes a live folder at the top of the pins, holding what it lists now; only what
    /// comes after counts as new. A page with no feed says so, and a feed followed already shows its folder.
    func follow(_ address: String) {
        let input = URLInput.resolve(address)
        guard canFollow(input), let url = URL(string: input) else { return }
        Trace.log("following \(Trace.site(input))")
        LiveFolders.find(url) { [weak self] found in
            guard let self else { return }
            guard case let .feed(feedURL, feed) = found else {
                Trace.log("following: no feed found")
                return showNotice(L("live.none.title"), detail: L("live.none.detail"))
            }
            if let existing = LiveFolders.liveFolders(in: space.pinned + space.today).first(where: { $0.feed?.url == feedURL.absoluteString }) {
                existing.expanded = true
                reloadSidebar()
                sidebar.reveal(existing)
                return
            }
            let title = feed.title.isEmpty ? url.host ?? input : feed.title
            let folder = SidebarItem(folder: String(title.prefix(60)))
            folder.icon = "dot.radiowaves.left.and.right"
            folder.feed = LiveFeed(url: feedURL.absoluteString, site: feed.site ?? input)
            folder.feed?.checked = Date()
            folder.refresh(with: feed.entries, markRead: true)
            space.place(folder, in: .pinned, at: 0)
            reloadSidebar()
            sidebar.reveal(folder)
            store.setNeedsSave()
        }
    }

    /// File › New Live Folder: the address of a site, or of its feed.
    func newLiveFolder() {
        guard !isPrivate else { return }
        ask(L("live.new.title"), placeholder: L("live.new.placeholder"), confirm: L("live.new.confirm")) { [weak self] text in
            self?.follow(text)
        }
    }

    func refreshLive(_ folder: SidebarItem) {
        group.liveFolders.refresh(folder) { [weak self] added in
            if added == nil { self?.showNotice(L("live.failed.title"), detail: L("live.failed.detail")) }
        }
    }

    func markRead(_ folder: SidebarItem) {
        folder.children.forEach { $0.isUnread = false }
        reloadSidebar()
        store.setNeedsSave()
    }

    /// The folder stays, with its tabs, as a plain one.
    func unfollow(_ folder: SidebarItem) {
        folder.feed = nil
        folder.children.forEach { $0.isUnread = false }
        reloadSidebar()
        store.setNeedsSave()
    }
}
