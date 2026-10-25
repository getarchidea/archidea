import Foundation
import ArchideaCore

/// Keeps the live folders up to date: soon after launch and every half hour while the browser runs, it reads each
/// one's feed and brings in what's new (`SidebarItem.refresh`). It also finds the feed behind an address, to follow it.
/// Feeds are fetched as files, outside the engine: no page runs, and they need no cookies.
final class LiveFolders {
    static let interval: TimeInterval = 30 * 60

    /// The normal windows' group, which owns this.
    private unowned let group: WindowGroup
    private var timer: Timer?
    /// Folders being read now, so a timer firing during a slow fetch doesn't fetch them twice.
    private var reading: Set<UUID> = []

    init(group: WindowGroup) {
        self.group = group
        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in self?.refreshDue() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.refreshDue() }
    }

    private var state: AppState { group.store.state }

    /// Every live folder whose last read is older than `interval` (or that was never read).
    func refreshDue() {
        let due = Date().addingTimeInterval(-Self.interval)
        for space in state.spaces {
            for folder in Self.liveFolders(in: space.pinned) where (folder.feed?.checked ?? .distantPast) < due { refresh(folder) }
        }
    }

    static func liveFolders(in items: [SidebarItem]) -> [SidebarItem] {
        items.flatMap { $0.isLive ? [$0] : $0.isFolder ? liveFolders(in: $0.children) : [] }
    }

    /// Reads `folder`'s feed now and brings in what's new; `done` hears how many came in (nil: the feed couldn't be
    /// read).
    func refresh(_ folder: SidebarItem, done: ((Int?) -> Void)? = nil) {
        guard let feed = folder.feed, let url = URL(string: feed.url), reading.insert(folder.id).inserted else {
            done?(nil)
            return
        }
        var request = Self.request(url)
        if let etag = feed.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let modified = feed.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        URLSession.shared.dataTask(with: request) { data, response, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                reading.remove(folder.id)
                let http = response as? HTTPURLResponse
                if http?.statusCode == 304 {
                    folder.feed?.checked = Date()
                    group.store.setNeedsSave()
                    done?(0)
                    return
                }
                guard http.map({ (200..<300).contains($0.statusCode) }) ?? false, let data,
                      let parsed = FeedParser.parse(data, base: url) else {
                    Trace.log("live folder \(folder.traceName): its feed couldn't be read (\(http?.statusCode ?? 0))")
                    done?(nil)
                    return
                }
                folder.feed?.checked = Date()
                folder.feed?.etag = http?.value(forHTTPHeaderField: "ETag")
                folder.feed?.lastModified = http?.value(forHTTPHeaderField: "Last-Modified")
                // Open tabs and the ones some window has in front stay, however old.
                let added = folder.refresh(with: parsed.entries) { tab in
                    group.liveTab(for: tab) != nil || state.space(containing: tab).map { state.isInFront(tab, in: $0) } == true
                }
                Trace.log("live folder \(folder.traceName): \(added.count) new")
                if !added.isEmpty { group.sidebarChanged(by: nil) }
                group.store.setNeedsSave()
                done?(added.count)
            }
        }.resume()
    }

    enum Found {
        case feed(url: URL, feed: Feed)
        case none
    }

    /// The feed behind `address`: the address itself when it is one, else a feed the page names in its head, else one
    /// at a usual place on the site. Calls back on the main thread.
    static func find(_ address: URL, then: @escaping (Found) -> Void) {
        fetch(address) { data, finalURL in
            if let data, let feed = FeedParser.parse(data, base: finalURL) { return then(.feed(url: finalURL, feed: feed)) }
            let html = data.flatMap { String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .isoLatin1) } ?? ""
            let named = FeedParser.feedLinks(inHTML: html, base: finalURL)
            tryEach(named + FeedParser.guesses(for: finalURL).filter { !named.contains($0) }, then: then)
        }
    }

    private static func tryEach(_ candidates: [URL], then: @escaping (Found) -> Void) {
        guard let first = candidates.first else { return then(.none) }
        fetch(first) { data, finalURL in
            if let data, let feed = FeedParser.parse(data, base: finalURL) { return then(.feed(url: finalURL, feed: feed)) }
            tryEach(Array(candidates.dropFirst()), then: then)
        }
    }

    private static func fetch(_ url: URL, then: @escaping (Data?, URL) -> Void) {
        URLSession.shared.dataTask(with: request(url)) { data, response, _ in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            DispatchQueue.main.async { then(ok ? data : nil, response?.url ?? url) }
        }.resume()
    }

    /// Some sites turn away requests that don't say they're a browser.
    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Archidea",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/rss+xml, application/atom+xml, application/xml;q=0.9, text/html;q=0.8, */*;q=0.5",
                         forHTTPHeaderField: "Accept")
        return request
    }
}
