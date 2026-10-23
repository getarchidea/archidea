import AppKit

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
        if let data = try? Data(contentsOf: Paths.state),
           let decoded = try? JSONDecoder.drift.decode(AppState.self, from: data),
           !decoded.spaces.isEmpty {
            state = decoded
        } else {
            state = AppState()
        }
        archiveStaleTabs()
    }

    private func archiveStaleTabs() {
        let hours = state.settings.archiveHours
        guard hours > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(hours) * 60 * 60)
        for space in state.spaces {
            space.today.removeAll { $0.lastActive < cutoff }
            if let selected = space.selectedID, space.find(selected) == nil { space.selectedID = nil }
        }
    }

    func setNeedsSave() {
        guard persists else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard persists else { return }
        guard let data = try? JSONEncoder.drift.encode(state) else { return }
        try? data.write(to: Paths.state, options: .atomic)
    }

    // MARK: favicons survive restarts, so unloaded pins keep their icons

    private var faviconCache: [UUID: NSImage] = [:]

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
        DispatchQueue.global(qos: .utility).async { try? png.write(to: url, options: .atomic) }
    }
}

extension JSONEncoder {
    static let drift: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
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
