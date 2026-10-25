import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Where a live folder fills itself from, and what it remembers between looks.
public struct LiveFeed: Codable, Equatable {
    /// The feed's address (RSS or Atom).
    public var url: String
    /// The site the feed belongs to, for the folder's icon and a way back to it.
    public var site: String?
    /// The last time the feed was read.
    public var checked: Date?
    /// What the server said about its copy last time, to ask whether anything changed since.
    public var etag: String?
    public var lastModified: String?
    /// Entries taken out of the folder (by hand, or let go as old), newest last, so they don't come back.
    public var dismissed: [String]

    /// How many taken-out entries are remembered; feeds only list their latest ones anyway.
    public static let dismissedLimit = 300

    public init(url: String, site: String? = nil) {
        self.url = url
        self.site = site
        dismissed = []
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        site = try c.decodeIfPresent(String.self, forKey: .site)
        checked = try c.decodeIfPresent(Date.self, forKey: .checked)
        etag = try c.decodeIfPresent(String.self, forKey: .etag)
        lastModified = try c.decodeIfPresent(String.self, forKey: .lastModified)
        dismissed = try c.decodeIfPresent([String].self, forKey: .dismissed) ?? []
    }

    public mutating func dismiss(_ entry: String) {
        dismissed.removeAll { $0 == entry }
        dismissed.append(entry)
        if dismissed.count > Self.dismissedLimit { dismissed.removeFirst(dismissed.count - Self.dismissedLimit) }
    }
}

/// One thing a feed lists: a post, a video, a release.
public struct FeedEntry: Equatable {
    /// What stays the same for it between reads: its guid or id, else its address.
    public let id: String
    public let title: String
    public let url: String

    public init(id: String, title: String, url: String) {
        self.id = id
        self.title = title
        self.url = url
    }
}

public struct Feed: Equatable {
    public let title: String
    /// The site's address, as the feed gives it.
    public let site: String?
    /// Newest first, as feeds list them.
    public let entries: [FeedEntry]
}

extension SidebarItem {
    /// The tabs a live folder brought in that haven't been opened.
    public var unreadCount: Int { children.filter(\.isUnread).count }

    /// Brings a live folder up to date with its feed's `entries` (newest first). Entries it doesn't have come in at
    /// the top, unread unless `markRead` (the first fill: only what comes after following counts as new); those
    /// taken out by hand stay out. It holds `limit` of the feed's tabs at most and lets the oldest go first, except
    /// those `keep` holds on to (open, in front). Tabs put in by hand are the person's and stay. Returns the tabs that
    /// came in.
    @discardableResult
    public func refresh(with entries: [FeedEntry], limit: Int = 30, markRead: Bool = false,
                        keep: (SidebarItem) -> Bool = { _ in false }) -> [SidebarItem] {
        guard isFolder, let feed else { return [] }
        var known = Set(children.compactMap(\.entryID)).union(feed.dismissed)
        var added: [SidebarItem] = []
        for entry in entries.prefix(limit) where !entry.url.isEmpty {
            guard known.insert(entry.id).inserted else { continue }
            let tab = SidebarItem(tab: entry.url, title: entry.title)
            tab.entryID = entry.id
            tab.isUnread = !markRead
            // A live folder lives among the pins, whose tabs keep the address they came with.
            tab.pinnedURL = entry.url
            added.append(tab)
        }
        children.insert(contentsOf: added, at: 0)
        var excess = children.filter { $0.entryID != nil }.count - limit
        for tab in children.reversed() where excess > 0 && !keep(tab) {
            guard let entry = tab.entryID else { continue }
            children.removeAll { $0 === tab }
            // Let go as old, it isn't brought in again while the feed still lists it.
            self.feed?.dismiss(entry)
            excess -= 1
        }
        return added
    }
}

/// Reads RSS 2.0, RSS 1.0 (RDF) and Atom, and finds the feeds a page names.
public enum FeedParser {
    /// Nil when `data` is none of the three, or names nothing. Relative addresses (Atom's) are read against `base`.
    public static func parse(_ data: Data, base: URL? = nil) -> Feed? {
        let reader = Reader(base: base)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = reader
        guard parser.parse() || reader.isFeed, reader.isFeed else { return nil }
        return Feed(title: reader.feedTitle.trimmingCharacters(in: .whitespacesAndNewlines), site: reader.site,
                    entries: reader.entries)
    }

    /// The feeds a page names in its head (`<link rel="alternate" type="application/rss+xml" href=…>`), in the
    /// page's order, as absolute addresses.
    public static func feedLinks(inHTML html: String, base: URL) -> [URL] {
        guard let tag = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive]),
              let attribute = try? NSRegularExpression(pattern: "([a-zA-Z-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))")
        else { return [] }
        let text = html as NSString
        var links: [URL] = []
        for match in tag.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            let element = text.substring(with: match.range) as NSString
            var values: [String: String] = [:]
            for pair in attribute.matches(in: element as String, range: NSRange(location: 0, length: element.length)) {
                let name = element.substring(with: pair.range(at: 1)).lowercased()
                let value = (2...4).map { pair.range(at: $0) }.first { $0.location != NSNotFound }.map(element.substring(with:)) ?? ""
                values[name] = value
            }
            let rel = (values["rel"] ?? "").lowercased().split(separator: " ")
            let type = (values["type"] ?? "").lowercased()
            guard rel.contains("alternate"), type.contains("rss+xml") || type.contains("atom+xml"),
                  let href = values["href"]?.replacingOccurrences(of: "&amp;", with: "&"), !href.isEmpty,
                  let url = URL(string: href, relativeTo: base)?.absoluteURL, !links.contains(url) else { continue }
            links.append(url)
        }
        return links
    }

    /// Where feeds often are when a page names none: the usual paths at the site's root.
    public static func guesses(for page: URL) -> [URL] {
        guard let scheme = page.scheme, let host = page.host else { return [] }
        let root = "\(scheme)://\(host)\(page.port.map { ":\($0)" } ?? "")"
        return ["/feed", "/rss", "/feed.xml", "/rss.xml", "/atom.xml", "/index.xml"].compactMap { URL(string: root + $0) }
    }

    private final class Reader: NSObject, XMLParserDelegate {
        let base: URL?
        private(set) var isFeed = false
        private(set) var feedTitle = ""
        private(set) var site: String?
        private(set) var entries: [FeedEntry] = []

        private var path: [String] = []
        private var text = ""
        private var inEntry = false
        private var entryTitle = ""
        private var entryLink: String?
        private var entryID: String?

        init(base: URL?) { self.base = base }

        private func resolved(_ link: String) -> String {
            let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
            return URL(string: trimmed, relativeTo: base)?.absoluteString ?? trimmed
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            if path.isEmpty { isFeed = ["rss", "feed", "RDF"].contains(name) }
            guard isFeed else { return parser.abortParsing() }
            path.append(name)
            text = ""
            switch name {
            case "item", "entry":
                inEntry = true
                entryTitle = ""
                entryLink = nil
                entryID = nil
            case "link" where attributes["href"] != nil:
                // Atom's link: the page itself is the alternate one, or one with no rel at all.
                let rel = attributes["rel"] ?? "alternate"
                guard rel == "alternate", let href = attributes["href"] else { break }
                if inEntry { if entryLink == nil { entryLink = resolved(href) } } else if site == nil { site = resolved(href) }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            text += String(data: CDATABlock, encoding: .utf8) ?? ""
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Only the feed's own elements and its entries' count, not those of other vocabularies inside them.
            let own = namespaceURI.map { Self.feedNamespaces.contains($0) } ?? true
            if inEntry, own {
                switch name {
                case "title" where entryTitle.isEmpty: entryTitle = value
                case "link" where entryLink == nil && !value.isEmpty: entryLink = resolved(value)
                case "guid", "id": if entryID == nil, !value.isEmpty { entryID = value }
                case "item", "entry":
                    inEntry = false
                    if let link = entryLink, entries.count < 100 {
                        entries.append(FeedEntry(id: entryID ?? link, title: entryTitle, url: link))
                    }
                default: break
                }
            } else if own, path.count <= 3 {
                // The channel's (or the feed's) own title and site.
                switch name {
                case "title" where feedTitle.isEmpty: feedTitle = value
                case "link" where site == nil && !value.isEmpty: site = resolved(value)
                default: break
                }
            }
            if !path.isEmpty { path.removeLast() }
            text = ""
        }

        /// RSS 2.0 has no namespace; RSS 1.0 and Atom have these.
        private static let feedNamespaces: Set<String> = ["", "http://www.w3.org/2005/Atom", "http://purl.org/rss/1.0/",
                                                          "http://www.w3.org/1999/02/22-rdf-syntax-ns#"]
    }
}
