import AppKit
import ArdiaCore

/// Chrome's downloads, kept current from the engine's events: what the sidebar's downloads button and panel show.
final class Downloads {
    static let shared = Downloads()

    struct Item: Equatable {
        enum State: String { case downloading, finished, cancelled, failed }

        let id: String
        var url: String
        var filename: String
        var path: String
        var state: State
        var paused: Bool
        var received: Double
        /// -1 while the size isn't known.
        var total: Double
        /// Bytes per second.
        var speed: Double
        var dangerous: Bool
        var error: String?
        var offTheRecord: Bool
        var started: Date

        init?(_ json: [String: Any]) {
            guard let id = json["id"] as? String else { return nil }
            self.id = id
            url = json["url"] as? String ?? ""
            path = json["path"] as? String ?? ""
            let name = json["filename"] as? String ?? ""
            filename = name.isEmpty ? (path as NSString).lastPathComponent : name
            state = State(rawValue: json["state"] as? String ?? "") ?? .downloading
            paused = json["paused"] as? Bool ?? false
            received = json["received"] as? Double ?? 0
            total = json["total"] as? Double ?? -1
            speed = json["speed"] as? Double ?? 0
            dangerous = json["dangerous"] as? Bool ?? false
            error = json["error"] as? String
            offTheRecord = json["offTheRecord"] as? Bool ?? false
            started = Date(timeIntervalSince1970: (json["startTime"] as? Double ?? 0) / 1000)
        }

        var active: Bool { state == .downloading }
        /// 0…1, or nil while the size isn't known.
        var fraction: Double? { total > 0 ? min(1, received / total) : state == .finished ? 1 : nil }
        var fileURL: URL? { path.isEmpty ? nil : URL(fileURLWithPath: path) }
        var exists: Bool { !path.isEmpty && FileManager.default.fileExists(atPath: path) }
    }

    /// Newest first.
    private(set) var items: [Item] = []
    /// Downloads that finished since the panel was last looked at: the button shows a dot for them.
    private(set) var unseen = false
    private var observers: [UUID: () -> Void] = [:]
    private var profile: ArdiaCoreProfile?

    func start(profile: ArdiaCoreProfile) {
        self.profile = profile
        EngineEvents.on("downloads.changed") { [weak self] payload in
            guard let json = payload["download"] as? [String: Any], let item = Item(json) else { return }
            self?.upsert(item)
        }
        EngineEvents.on("downloads.removed") { [weak self] payload in
            guard let self, let id = payload["id"] as? String else { return }
            items.removeAll { $0.id == id }
            changed()
        }
        // The engine starts watching a profile's downloads with its first downloads call.
        EngineCall.call("ac_downloads_list", profile: profile) { [weak self] reply in
            guard let self, let list = reply?["downloads"] as? [[String: Any]] else { return }
            items = list.compactMap(Item.init).filter { !$0.offTheRecord }
            changed()
        }
    }

    func observe(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func stopObserving(_ id: UUID) { observers[id] = nil }

    func markSeen() {
        guard unseen else { return }
        unseen = false
        changed()
    }

    // MARK: actions

    func pause(_ item: Item) { act("ac_downloads_pause", item) }
    func resume(_ item: Item) { act("ac_downloads_resume", item) }
    func cancel(_ item: Item) { act("ac_downloads_cancel", item) }
    /// Keeps a download Chrome flagged as dangerous or insecure.
    func keep(_ item: Item) { act("ac_downloads_keep", item) }
    /// Takes a finished, failed or cancelled download off the list; the file stays where it is.
    func remove(_ item: Item) { act("ac_downloads_remove", item) }

    func clearDone() {
        for item in items where !item.active { remove(item) }
    }

    /// Opens the file; one that has gone from disk opens its folder instead.
    func open(_ item: Item) {
        guard let url = item.fileURL else { return }
        if item.exists { NSWorkspace.shared.open(url) } else { reveal(item) }
    }

    func reveal(_ item: Item) {
        guard let url = item.fileURL else { return }
        if item.exists {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    static var folder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    // MARK: private

    private func act(_ call: String, _ item: Item) {
        guard let profile else { return }
        EngineCall.call(call, profile: profile, args: ["id": item.id]) { reply in
            if let error = reply?["error"] { Trace.log("downloads: \(call) \(error)") }
        }
    }

    private func upsert(_ item: Item) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            let was = items[index]
            items[index] = item
            if was.active, item.state == .finished { finished(item) }
        } else {
            items.insert(item, at: 0)
            if item.state == .finished { finished(item) }
        }
        changed()
    }

    private func finished(_ item: Item) {
        unseen = true
        // Bounces the Downloads stack in the Dock, as Safari and Chrome do.
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: item.path)
    }

    private func changed() {
        let active = items.filter(\.active).count
        NSApp.dockTile.badgeLabel = active > 0 ? "\(active)" : nil
        observers.values.forEach { $0() }
    }
}
