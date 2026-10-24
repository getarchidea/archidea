import AppKit
import ArchideaCore

enum Paths {
    static let root: URL = {
        if let dir = ProcessInfo.processInfo.environment["DRIFT_DATA_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true).standardizedFileURL
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Archidea", isDirectory: true)
    }()

    static let chromium = root.appendingPathComponent("Chromium", isDirectory: true)
    static let state = root.appendingPathComponent("state.json")
    /// The last state that read back fine, from the previous launch.
    static let stateBackup = root.appendingPathComponent("state.backup.json")
    static let favicons = root.appendingPathComponent("Favicons", isDirectory: true)

    static func prepare() {
        if ProcessInfo.processInfo.environment["DRIFT_DATA_DIR"] == nil { LegacyData.migrate(into: root) }
        for dir in [root, chromium, favicons] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

final class Store {
    let state: AppState
    private var pendingSave: DispatchWorkItem?
    /// Writes happen here, in order, so the main thread only pays for encoding; quitting waits for the last one.
    private let writer = DispatchQueue(label: "app.archidea.state-writer", qos: .utility)
    /// False for a private window: its sidebar and favicons stay in memory and are gone when it closes.
    let persists: Bool

    /// A private window's store: nothing is read from or written to disk.
    init(ephemeral state: AppState) {
        self.state = state
        persists = false
    }

    init() {
        persists = true
        Paths.prepare()
        state = Self.load()
        if state.repair() { Trace.log("state: repaired what the saved sidebar got wrong") }
        archiveStaleTabs()
        sweepFavicons()
    }

    /// The saved sidebar. A file that doesn't read back (cut short, from a newer version) is never written over:
    /// it's set aside under its own name and the backup from the previous launch takes its place; only with
    /// neither does the sidebar start fresh. Every good read refreshes the backup.
    private static func load() -> AppState {
        let fm = FileManager.default
        func read(_ url: URL) throws -> AppState? {
            guard fm.fileExists(atPath: url.path) else { return nil }
            let decoded = try JSONDecoder.drift.decode(AppState.self, from: Data(contentsOf: url))
            return decoded.spaces.isEmpty ? nil : decoded
        }
        do {
            if let state = try read(Paths.state) {
                try? fm.removeItem(at: Paths.stateBackup)
                try? fm.copyItem(at: Paths.state, to: Paths.stateBackup)
                return state
            }
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let aside = Paths.root.appendingPathComponent("state-unreadable-\(stamp).json")
            try? fm.moveItem(at: Paths.state, to: aside)
            Trace.log("state: state.json doesn't read (\(error)); kept as \(aside.lastPathComponent)")
        }
        if let backup = try? read(Paths.stateBackup) {
            Trace.log("state: restored from the backup")
            return backup
        }
        return AppState()
    }

    /// At launch nothing is open yet, so every stale Today tab simply goes (onto the reopen list, as when the windows
    /// archive them while running, keeping the ones in front and those playing sound).
    private func archiveStaleTabs() {
        let hours = state.settings.archiveHours
        guard hours > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(hours) * 60 * 60)
        for space in state.spaces {
            let stale = space.staleToday(before: cutoff)
            stale.forEach(state.remember)
            space.today.removeAll { item in stale.contains { $0 === item } }
        }
    }

    /// Saves a moment later, once a burst of changes is over.
    func setNeedsSave() {
        guard persists else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save(waiting: false) }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Saves before returning (quitting, closing the window).
    func saveNow() { save(waiting: true) }

    /// The sidebar is encoded here, on the main thread that changes it, so the file is always one consistent moment;
    /// writing it out happens on `writer`.
    private func save(waiting: Bool) {
        pendingSave?.cancel()
        pendingSave = nil
        guard persists else { return }
        let data: Data
        do {
            data = try JSONEncoder.drift.encode(state)
        } catch {
            return Trace.log("state: not encoded (\(error))")
        }
        let write = {
            do {
                try data.write(to: Paths.state, options: .atomic)
            } catch {
                Trace.log("state: not saved (\(error))")
            }
        }
        if waiting { writer.sync(execute: write) } else { writer.async(execute: write) }
    }

    // MARK: favicons survive restarts, so unloaded pins keep their icons

    private var faviconCache: [UUID: NSImage] = [:]

    /// Icons of items that are gone (closed, removed, archived) go once at launch; nothing else ever asks for them.
    private func sweepFavicons() {
        let kept = Set(state.spaces.flatMap(\.allTabs).map(\.id.uuidString))
        writer.async {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: Paths.favicons, includingPropertiesForKeys: nil) else { return }
            var removed = 0
            for file in files where file.pathExtension == "png" && !kept.contains(file.deletingPathExtension().lastPathComponent) {
                if (try? fm.removeItem(at: file)) != nil { removed += 1 }
            }
            if removed > 0 { Trace.log("favicons: \(removed) icons of items that are gone removed") }
        }
    }

    func favicon(for item: SidebarItem) -> NSImage? {
        if let cached = faviconCache[item.id] { return cached }
        guard persists else { return nil }
        let url = Paths.favicons.appendingPathComponent("\(item.id.uuidString).png")
        guard let image = NSImage(contentsOf: url) else { return nil }
        faviconCache[item.id] = image
        return image
    }

    func setFavicon(_ image: NSImage, for item: SidebarItem) {
        guard faviconCache[item.id] !== image else { return }
        faviconCache[item.id] = image
        guard persists else { return }
        let url = Paths.favicons.appendingPathComponent("\(item.id.uuidString).png")
        // Rendered at 2x, so cached icons stay sharp on Retina; loading gives back a 16pt image.
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return }
        bitmap.size = NSSize(width: 16, height: 16)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        writer.async { try? png.write(to: url, options: .atomic) }
    }
}

extension JSONEncoder {
    static let drift: JSONEncoder = {
        let encoder = JSONEncoder()
        // Compact: the whole sidebar is written after every change, and a big import makes it large.
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let drift: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
