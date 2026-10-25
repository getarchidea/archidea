import ArdiaCore
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
        profile.services.history(maxURLs: 5000, maxVisits: 1) { [weak self] result in
            guard let self else { return }
            loading = false
            loadedAt = Date()
            switch result {
            case let .success(visits):
                entries = visits.compactMap { visit in
                    guard visit.url.hasPrefix("http") else { return nil }
                    let host = URL(string: visit.url)?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? ""
                    let last = visit.times.first.map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
                    return Entry(url: visit.url, title: visit.title, host: host, visits: visit.visits, lastVisit: last)
                }
            case let .failure(failure):
                Trace.log("history: \(failure)")
                entries = []
            }
            done()
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
