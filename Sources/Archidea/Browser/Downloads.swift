import AppKit
import ArdiaCore

/// Chrome's downloads, kept current from the engine's events: what the sidebar's downloads button and panel show.
final class Downloads {
    static let shared = Downloads()

    /// A download as the engine reports it (`ac_downloads_list`, the `downloads.changed` event).
    struct Item: Equatable, Decodable {
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

        private enum CodingKeys: String, CodingKey {
            case id, url, path, filename, state, paused, received, total, speed, dangerous, error, offTheRecord, startTime
        }

        /// Only the ID must be there; anything else missing (or of a kind this version doesn't know) takes a default.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? ""
            path = (try? c.decodeIfPresent(String.self, forKey: .path)) ?? ""
            let name = (try? c.decodeIfPresent(String.self, forKey: .filename)) ?? ""
            filename = name.isEmpty ? (path as NSString).lastPathComponent : name
            state = ((try? c.decodeIfPresent(String.self, forKey: .state)) ?? nil).flatMap(State.init(rawValue:)) ?? .downloading
            paused = (try? c.decodeIfPresent(Bool.self, forKey: .paused)) ?? false
            received = (try? c.decodeIfPresent(Double.self, forKey: .received)) ?? 0
            total = (try? c.decodeIfPresent(Double.self, forKey: .total)) ?? -1
            speed = (try? c.decodeIfPresent(Double.self, forKey: .speed)) ?? 0
            dangerous = (try? c.decodeIfPresent(Bool.self, forKey: .dangerous)) ?? false
            error = try? c.decodeIfPresent(String.self, forKey: .error)
            offTheRecord = (try? c.decodeIfPresent(Bool.self, forKey: .offTheRecord)) ?? false
            started = Date(timeIntervalSince1970: ((try? c.decodeIfPresent(Double.self, forKey: .startTime)) ?? 0) / 1000)
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
        struct Changed: Decodable { let download: Item }
        struct Removed: Decodable { let id: String }
        EngineEvents.on("downloads.changed", as: Changed.self) { [weak self] payload in
            self?.upsert(payload.download)
        }
        EngineEvents.on("downloads.removed", as: Removed.self) { [weak self] payload in
            guard let self else { return }
            items.removeAll { $0.id == payload.id }
            changed()
        }
        // The engine starts watching a profile's downloads with its first downloads call.
        profile.services.downloads { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(list):
                items = list.filter { !$0.offTheRecord }
                changed()
            case let .failure(failure):
                Trace.log("downloads: list \(failure)")
            }
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

    func pause(_ item: Item) { act(.pause, item) }
    func resume(_ item: Item) { act(.resume, item) }
    func cancel(_ item: Item) { act(.cancel, item) }
    /// Keeps a download Chrome flagged as dangerous or insecure.
    func keep(_ item: Item) { act(.keep, item) }
    /// Takes a finished, failed or cancelled download off the list; the file stays where it is.
    func remove(_ item: Item) { act(.remove, item) }

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

    private func act(_ action: EngineServices.DownloadAction, _ item: Item) {
        guard let profile else { return }
        profile.services.download(item.id, action) { result in
            if case let .failure(failure) = result { Trace.log("downloads: \(action) \(failure)") }
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
