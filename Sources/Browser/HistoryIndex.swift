import Foundation

/// The profile's browsing history for the address bar's suggestions. The engine hands the whole history over in
/// one call (most recent first); it is kept in memory and refreshed when the bar opens, at most twice a minute.
final class HistoryIndex {
    struct Entry {
        let url: String
        let title: String
        let host: String
        let visits: Int
        let lastVisit: Date
    }

    private let profile: ArdiaCoreProfile
    private var entries: [Entry] = []
    private var loadedAt = Date.distantPast
    private var loading = false

    init(profile: ArdiaCoreProfile) { self.profile = profile }

    func refresh(then done: @escaping () -> Void = {}) {
        guard !loading, Date().timeIntervalSince(loadedAt) > 30 else { return done() }
        loading = true
        EngineCall.call("ac_history_query", profile: profile, args: ["maxUrls": 5000, "maxVisits": 1]) { [weak self] reply in
            guard let self else { return }
            loading = false
            loadedAt = Date()
            entries = (reply?["entries"] as? [[String: Any]] ?? []).compactMap { row in
                guard let url = row["u"] as? String, url.hasPrefix("http") else { return nil }
                let host = URL(string: url)?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? ""
                let last = (row["v"] as? [Double])?.first.map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
                return Entry(url: url, title: row["t"] as? String ?? "", host: host, visits: row["n"] as? Int ?? 1, lastVisit: last)
            }
            done()
        }
    }

    struct Site {
        let host: String
        let url: String
        let title: String
    }

    /// The sites visited most, lately weighing more than long ago: the start page's tiles. Sign-in hosts are left
    /// out (nobody goes back to them on purpose), and so is anything in `hidden`.
    func topSites(limit: Int, hidden: Set<String>) -> [Site] {
        let now = Date()
        var score: [String: Double] = [:]
        var best: [String: Entry] = [:]
        for entry in entries where !entry.host.isEmpty && !hidden.contains(entry.host) {
            let first = entry.host.split(separator: ".").first.map(String.init) ?? ""
            if ["accounts", "login", "auth", "signin", "sso", "oauth", "id"].contains(first) { continue }
            // Dev servers come and go.
            if entry.host == "localhost" || entry.host == "127.0.0.1" || entry.host.hasSuffix(".local") || entry.host.hasSuffix(".localhost") { continue }
            let days = max(0, now.timeIntervalSince(entry.lastVisit) / 86_400)
            score[entry.host, default: 0] += Double(entry.visits) * exp(-days / 30)
            // The site's name comes from its front page when that's in history, else its most visited page.
            let isRoot = (URL(string: entry.url)?.path ?? "").count <= 1
            if let current = best[entry.host] {
                let currentRoot = (URL(string: current.url)?.path ?? "").count <= 1
                if isRoot && !currentRoot || isRoot == currentRoot && entry.visits > current.visits { best[entry.host] = entry }
            } else {
                best[entry.host] = entry
            }
        }
        return score.sorted { $0.value > $1.value }.prefix(limit).compactMap { host, _ in
            guard let entry = best[host], let url = URL(string: entry.url), let scheme = url.scheme, let realHost = url.host else { return nil }
            return Site(host: host, url: "\(scheme)://\(realHost)/", title: entry.title)
        }
    }

    /// History changed in bulk (an import): the next refresh reads it again whenever it comes.
    func invalidate() { loadedAt = .distantPast }

    /// Best matches for what's typed: a site whose host starts with it first, then words in the address or title,
    /// weighed by how often and how lately it was visited.
    func matches(_ text: String, excluding: Set<String>, limit: Int) -> [Entry] {
        let query = text.lowercased().replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "www.", with: "")
        guard !query.isEmpty else { return [] }
        let now = Date()
        var scored: [(Entry, Double)] = []
        for entry in entries where !excluding.contains(entry.url) {
            let base: Double
            if entry.host.hasPrefix(query) {
                base = 3
            } else if entry.url.lowercased().contains(query) {
                base = 1.6
            } else if entry.title.lowercased().contains(query) {
                base = 1.2
            } else {
                continue
            }
            let days = max(0, now.timeIntervalSince(entry.lastVisit) / 86_400)
            let path = URL(string: entry.url)?.path ?? ""
            let root: Double = path.count <= 1 ? 0.6 : 0
            scored.append((entry, base + log(Double(entry.visits) + 1) * 0.6 + root - min(days, 60) / 30))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}
