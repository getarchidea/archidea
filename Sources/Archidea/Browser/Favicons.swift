import AppKit
import ArdiaCore

/// Icons for pages that aren't open: from the engine's favicon database (sites visited before, and what an import
/// brought along), with the site's own icon standing in for pages that have none. Looked up in batches, kept in memory.
final class Favicons {
    static let shared = Favicons()

    /// The normal profile's database; private windows read it too (theirs keeps none).
    var profile: ArdiaCoreProfile?

    private var found: [String: NSImage] = [:]
    private var missing: Set<String> = []
    private var waiting: [String: [(NSImage) -> Void]] = [:]
    private var scheduled = false

    func cached(_ url: String) -> NSImage? { found[url] }

    /// Calls `then` with the page's icon once known; never, when there's none.
    func lookUp(_ url: String, then: @escaping (NSImage) -> Void) {
        if let image = found[url] { return then(image) }
        guard !missing.contains(url), URL(string: url)?.scheme?.hasPrefix("http") == true else { return }
        let first = waiting[url] == nil
        waiting[url, default: []].append(then)
        guard first, !scheduled else { return }
        scheduled = true
        // Rows ask one by one as they draw; a turn of the run loop gathers them into one call.
        DispatchQueue.main.async { [weak self] in self?.fetch() }
    }

    /// After an import new icons exist for pages that had none.
    func forgetMisses() { missing.removeAll() }

    private func fetch() {
        scheduled = false
        guard let profile, !waiting.isEmpty else { return }
        let pages = Array(waiting.keys.prefix(500))
        profile.services.favicons(pages: pages, size: 32) { [weak self] result in
            guard let self else { return }
            let icons = (try? result.get()) ?? [:]
            for page in pages {
                let callbacks = waiting.removeValue(forKey: page) ?? []
                guard let data = icons[page], let image = NSImage(data: data) else {
                    missing.insert(page)
                    continue
                }
                image.size = NSSize(width: 16, height: 16)
                found[page] = image
                callbacks.forEach { $0(image) }
            }
            if !waiting.isEmpty { fetch() }
        }
    }
}
