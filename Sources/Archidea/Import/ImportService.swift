import AppKit
import ArchideaCore

/// What can be brought over from another browser.
enum ImportPart: String, CaseIterable {
    /// Arc's sidebar: spaces, pinned tabs, folders and favorites.
    case spaces
    case tabs, bookmarks, history, passwords, cookies

    var title: String { L("import.part.\(rawValue)") }
    var needsKeychain: Bool { self == .passwords || self == .cookies }
}

struct ImportSummary {
    var spaces = 0, pins = 0, tabs = 0, bookmarks = 0, history = 0, passwords = 0, cookies = 0
    var warnings: [String] = []

    var lines: [String] {
        [(spaces, "import.done.spaces"), (pins, "import.done.pins"), (tabs, "import.done.tabs"), (bookmarks, "import.done.bookmarks"),
         (history, "import.done.history"), (passwords, "import.done.passwords"), (cookies, "import.done.cookies")]
            .filter { $0.0 > 0 }.map { L($0.1, $0.0) }
    }

    /// What came over for one part, for its card ("spaces: 2 · pinned tabs: 40"); nil when nothing did.
    func detail(for part: ImportPart) -> String? {
        let counts: [(Int, String)]
        switch part {
        case .spaces: counts = [(spaces, "count.spaces"), (pins, "count.pins")]
        case .tabs: counts = [(tabs, "count.tabs")]
        case .bookmarks: counts = [(bookmarks, "count.bookmarks")]
        case .history: counts = [(history, "count.history")]
        case .passwords: counts = [(passwords, "count.passwords")]
        case .cookies: counts = [(cookies, "count.cookies")]
        }
        let text = counts.filter { $0.0 > 0 }.map { plural($0.1, $0.0) }.joined(separator: " · ")
        return text.isEmpty ? nil : text
    }
}

/// Reads another browser's data with the readers in Readers and puts it where it belongs:
/// spaces, pins and open tabs into Drift's sidebar; bookmarks, history, passwords and cookies into the engine.
final class ImportService {
    static let shared = ImportService()
    let importer: Importer

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let icons = Paths.root.appendingPathComponent("ImportIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        importer = Importer(discovery: BrowserDiscovery(applicationSupport: support, locateApp: AppIcons.locate,
                                                        iconFor: { app, id in AppIcons.png(for: app, id: id, directory: icons) }))
    }

    /// The source browser if it's open. Its sign-ins keep changing while it runs (sessions rotate their cookies),
    /// so a copy taken now goes stale at once, and a session carried on in two browsers trips sites' theft checks
    /// (Google signs the copy out). Sign-ins are brought over once it has quit.
    func runningApp(of source: BrowserSource) -> NSRunningApplication? {
        guard source.family != .safari, let path = source.appPath else { return nil }
        let target = URL(fileURLWithPath: path).standardizedFileURL
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == target }
    }

    /// Asks the app to quit and calls back once it has (false if it's still running after 15 seconds).
    func quit(_ app: NSRunningApplication, completion: @escaping (Bool) -> Void) {
        app.terminate()
        let deadline = Date().addingTimeInterval(15)
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            guard app.isTerminated || Date() > deadline else { return }
            timer.invalidate()
            completion(app.isTerminated)
        }
    }

    func sources() -> [BrowserSource] {
        importer.discovery.list().filter { $0.id != BrowserDefinition.diaTabsId }
    }

    func parts(for source: BrowserSource, profile: BrowserProfile?) -> [ImportPart] {
        if source.family == .safari { return [.bookmarks, .history, .tabs, .passwords, .cookies] }
        let kinds = Set(profile?.available ?? [])
        var parts: [ImportPart] = []
        if source.id == "arc", kinds.contains(.spaces) || kinds.contains(.pinnedTabs) {
            parts.append(.spaces)
        }
        if kinds.contains(.tabs), source.id != "arc" { parts.append(.tabs) }
        if kinds.contains(.bookmarks) { parts.append(.bookmarks) }
        if kinds.contains(.history) { parts.append(.history) }
        if kinds.contains(.passwords) { parts.append(.passwords) }
        if kinds.contains(.cookies) { parts.append(.cookies) }
        return parts
    }

    /// Reads off the main thread, then writes on it. `safariExport` is an archive from Safari's File › Export.
    func run(source: BrowserSource, profile: BrowserProfile?, parts: Set<ImportPart>, safariExport: URL? = nil,
             into controller: BrowserWindowController, progress: @escaping (String) -> Void,
             completion: @escaping (Result<ImportSummary, Error>) -> Void) {
        let importer = importer
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var read = ReadData()
                if source.family == .safari {
                    DispatchQueue.main.async { progress(L("import.progress.reading", source.name)) }
                    let export = try safariExport.map { try SafariExport.load($0) } ?? SafariDirect.load()
                    read.bookmarks = parts.contains(.bookmarks) ? export.bookmarks : nil
                    read.history = parts.contains(.history) ? export.profiles.flatMap(\.history) : []
                    read.tabs = parts.contains(.tabs) ? export.tabs.map { .tab(url: $0.url, title: $0.title) } : []
                    read.credentials = parts.contains(.passwords) ? export.credentials : []
                    read.cookies = parts.contains(.cookies) ? export.cookies : []
                    read.warnings = export.warnings.map(\.message)
                } else {
                    // Passwords and cookies need the browser's key from the keychain. When the person declines that
                    // prompt the rest still comes over, and the summary says what stayed behind.
                    var parts = parts
                    if source.needsKeychain, !parts.filter(\.needsKeychain).isEmpty, !importer.isUnlocked(source.id) {
                        DispatchQueue.main.async { progress(L("import.progress.keychain", source.name)) }
                        do {
                            try importer.unlock(browserId: source.id)
                        } catch {
                            Trace.log("import: \(source.name) key not available (\(error)); skipping passwords and cookies")
                            parts.subtract(parts.filter(\.needsKeychain))
                            read.warnings.append(L("import.keychainDeclined", source.name))
                        }
                    }
                    DispatchQueue.main.async { progress(L("import.progress.reading", source.name)) }
                    var kinds: [ImportKind] = []
                    if parts.contains(.spaces), source.id == "arc" { kinds += [.spaces, .pinnedTabs, .favorites] }
                    if parts.contains(.tabs) { kinds.append(.tabs) }
                    if parts.contains(.bookmarks) { kinds.append(.bookmarks) }
                    if parts.contains(.history) { kinds.append(.history) }
                    if parts.contains(.passwords) { kinds.append(.passwords) }
                    if parts.contains(.cookies) { kinds.append(.cookies) }
                    if let profile, !kinds.isEmpty {
                        let result = try importer.importData(browserId: source.id, profileId: profile.id, kinds: kinds,
                                                             options: ImportOptions(historyLimit: 200_000))
                        read.spaces = result.spaces.map(Self.space)
                        if !result.favorites.isEmpty {
                            let favorites = result.favorites.map { ImportedNode.tab(url: $0.url, title: $0.title) }
                            if read.spaces.isEmpty {
                                read.spaces = [ImportedSpace(name: source.name, colorHex: nil, symbol: nil, pinned: favorites, tabs: [])]
                            } else {
                                read.spaces[0].pinned.insert(contentsOf: favorites, at: 0)
                            }
                        }
                        read.tabs = result.tabs.map { .tab(url: $0.url, title: $0.customTitle ?? $0.title) }
                        read.bookmarks = result.bookmarks
                        read.history = result.history
                        read.credentials = result.credentials
                        read.cookies = result.cookies
                        read.warnings += result.warnings.map(\.message)
                        // Icons for what came over, read last so a problem with them costs nothing else.
                        do {
                            read.icons = try importer.favicons(browserId: source.id, profileId: profile.id, pages: read.pageURLs)
                        } catch {
                            Trace.log("import: no site icons from \(source.name) (\(error))")
                        }
                    }
                }
                DispatchQueue.main.async {
                    self.write(read, from: source.name, into: controller, progress: progress) { completion(.success($0)) }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// Passwords exported as CSV — from Apple's Passwords app (File › Export All Passwords), 1Password, Bitwarden…
    func importPasswords(csv file: URL, into controller: BrowserWindowController, progress: @escaping (String) -> Void,
                         completion: @escaping (Result<ImportSummary, Error>) -> Void) {
        do {
            var read = ReadData()
            read.credentials = try PasswordsCSV.parse(String(contentsOf: file, encoding: .utf8))
            write(read, from: file.deletingPathExtension().lastPathComponent, into: controller, progress: progress) { completion(.success($0)) }
        } catch {
            completion(.failure(error))
        }
    }

    private struct ReadData {
        var spaces: [ImportedSpace] = []
        var tabs: [ImportedNode] = []
        var bookmarks: BookmarkNode?
        var history: [HistoryEntry] = []
        var credentials: [Credential] = []
        var cookies: [Cookie] = []
        var warnings: [String] = []
        var icons: [FaviconReader.Icon] = []

        /// Every page the import brings into the sidebar or bookmarks, for their own icons.
        var pageURLs: Set<String> {
            var out = Set<String>()
            func add(_ node: ImportedNode) {
                switch node {
                case let .tab(url, _): out.insert(url)
                case let .folder(_, _, children, _): children.forEach(add)
                }
            }
            for space in spaces { (space.pinned + space.tabs).forEach(add) }
            tabs.forEach(add)
            func mark(_ bookmark: BookmarkNode) {
                if let url = bookmark.url { out.insert(url) }
                bookmark.children?.forEach(mark)
            }
            bookmarks.map(mark)
            return out
        }
    }

    private static func space(_ suggestion: SpaceSuggestion) -> ImportedSpace {
        func node(_ bookmark: BookmarkNode) -> ImportedNode? {
            switch bookmark.type {
            case .url: return bookmark.url.map { .tab(url: $0, title: bookmark.title) }
            case .folder: return .folder(title: bookmark.title, symbol: nil, children: (bookmark.children ?? []).compactMap(node), expanded: true)
            }
        }
        let color = suggestion.color ?? suggestion.colors?.first
        // Arc's spaces have an emoji or an icon of Arc's own, which counts only when SF Symbols has the same name.
        return ImportedSpace(name: suggestion.name, colorHex: color.flatMap { $0.hasPrefix("#") ? $0 : nil }, symbol: suggestion.emoji ?? suggestion.icon,
                             pinned: suggestion.pinned.compactMap(node), tabs: suggestion.tabs.map { .tab(url: $0.url, title: $0.customTitle ?? $0.title) })
    }

    // MARK: writing

    private func write(_ read: ReadData, from browser: String, into controller: BrowserWindowController,
                       progress: @escaping (String) -> Void, done: @escaping (ImportSummary) -> Void) {
        var summary = ImportSummary()
        summary.warnings = read.warnings
        let counted = controller.adoptImported(spaces: read.spaces, openTabs: read.tabs)
        summary.spaces = counted.spaces
        summary.pins = counted.pins
        summary.tabs = counted.tabs
        let profile = controller.profile

        var steps: [(@escaping () -> Void) -> Void] = []
        if let root = read.bookmarks {
            steps.append { next in
                progress(L("import.progress.bookmarks"))
                let ops = Self.bookmarkOps(root, browser: browser)
                summary.bookmarks = ops.filter { $0.kind == .url }.count
                Self.sequence(stride(from: 0, to: ops.count, by: 500).map { start in
                    { (after: @escaping () -> Void) in
                        profile.services.applyBookmarks(Array(ops[start..<min(start + 500, ops.count)]), timeout: Self.stepTimeout) { result in
                            if case let .failure(failure) = result { Trace.log("import: bookmarks \(failure)") }
                            after()
                        }
                    }
                }, then: next)
            }
        }
        if !read.history.isEmpty {
            steps.append { next in
                progress(L("import.progress.history"))
                let rows = read.history.map { EngineServices.ImportedVisit(url: $0.url, title: $0.title, visits: $0.visits, lastVisit: $0.lastVisit) }
                Self.sequence(stride(from: 0, to: rows.count, by: 2000).map { start in
                    { (after: @escaping () -> Void) in
                        profile.services.importHistory(Array(rows[start..<min(start + 2000, rows.count)]), timeout: Self.stepTimeout) { result in
                            switch result {
                            case .success: summary.history += min(2000, rows.count - start)
                            case let .failure(failure): Trace.log("import: history \(failure)")
                            }
                            after()
                        }
                    }
                }, then: {
                    controller.history.invalidate()
                    next()
                })
            }
        }
        if !read.credentials.isEmpty {
            steps.append { next in
                progress(L("import.progress.passwords"))
                Self.sequence(read.credentials.compactMap { credential -> ((@escaping () -> Void) -> Void)? in
                    let source = credential.realm.flatMap { $0.hasPrefix("http") ? $0 : nil } ?? credential.url
                    guard !credential.password.isEmpty, let url = URL(string: source), let scheme = url.scheme, let host = url.host else { return nil }
                    let origin = url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
                    return { after in
                        var json = (try? JSONSerialization.data(withJSONObject: ["origin": origin, "username": credential.username,
                                                                                 "password": credential.password])) ?? Data()
                        json.append(0)
                        json.withUnsafeBytes { bytes in
                            profile.services.addPassword(json: bytes, timeout: Self.stepTimeout) { result in
                                if case .success = result { summary.passwords += 1 }
                                after()
                            }
                        }
                        json.resetBytes(in: 0..<json.count)
                    }
                }, then: next)
            }
        }
        if !read.cookies.isEmpty {
            // Google signs a session out once its cookies show up in another browser (it binds them to the device
            // and browser that signed in), so Google and YouTube want one fresh sign-in; other sites carry over.
            if read.cookies.contains(where: { $0.domain.hasSuffix("google.com") || $0.domain.hasSuffix("youtube.com") }) {
                summary.warnings.append(L("import.googleNote"))
            }
            steps.append { next in
                progress(L("import.progress.cookies"))
                let wire = CookieWire.batches(read.cookies)
                Self.sequence(wire.batches.map { batch in
                    { after in
                        batch.withUnsafeBytes { bytes in
                            profile.services.importCookies(json: bytes, timeout: Self.stepTimeout) { result in
                                switch result {
                                case let .success(imported): summary.cookies += imported
                                case let .failure(failure): Trace.log("import: cookies \(failure)")
                                }
                                after()
                            }
                        }
                        batch.wipe()
                    }
                }, then: next)
            }
        }
        if !read.icons.isEmpty {
            steps.append { next in
                progress(L("import.progress.icons"))
                // Eight at a time: the engine writes each to its favicon database.
                let icons = read.icons
                let lanes = 8
                let group = DispatchGroup()
                for lane in 0..<lanes {
                    group.enter()
                    Self.sequence(stride(from: lane, to: icons.count, by: lanes).map { index in
                        { (after: @escaping () -> Void) in
                            guard let png = Self.png(icons[index].data) else { return after() }
                            profile.services.setFavicon(page: icons[index].page, icon: icons[index].icon, png: png,
                                                        timeout: Self.stepTimeout) { _ in after() }
                        }
                    }, then: { group.leave() })
                }
                group.notify(queue: .main) {
                    Trace.log("import: \(icons.count) site icons stored")
                    Favicons.shared.forgetMisses()
                    controller.refreshFavicons()
                    next()
                }
            }
        }
        Self.sequence(steps) { done(summary) }
    }

    /// An icon as PNG: Chromium keeps PNG already, Firefox also ICO and SVG.
    private static func png(_ data: Data) -> Data? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data }
        guard let image = NSImage(data: data) else { return nil }
        let side = 32
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// How long one write to the engine may take before the import moves on without it: a lost reply must not
    /// leave the import spinning for good.
    private static let stepTimeout: TimeInterval = 60

    /// Runs asynchronous steps one after another, then `then`.
    private static func sequence(_ steps: [(@escaping () -> Void) -> Void], then: @escaping () -> Void) {
        guard let first = steps.first else { return then() }
        first { sequence(Array(steps.dropFirst()), then: then) }
    }

    /// The imported tree as bookmark operations: the bar's links into a folder on the bar, the rest into one under
    /// Other Bookmarks, both named for the browser they came from.
    private static func bookmarkOps(_ root: BookmarkNode, browser: String) -> [EngineServices.BookmarkOp] {
        var ops: [EngineServices.BookmarkOp] = []
        let now = Date().timeIntervalSince1970 * 1000
        func add(_ node: BookmarkNode, parent: String) {
            let id = UUID().uuidString.lowercased()
            switch node.type {
            case .folder:
                ops.append(.init(id: id, kind: .folder, title: node.title, url: nil, added: node.dateAdded ?? now, parent: parent))
                node.children?.forEach { add($0, parent: id) }
            case .url:
                guard let url = node.url else { return }
                ops.append(.init(id: id, kind: .url, title: node.title.isEmpty ? url : node.title, url: url,
                                 added: node.dateAdded ?? now, parent: parent))
            }
        }
        let children = root.children ?? []
        let toolbar = children.filter { $0.role == "toolbar" }.flatMap { $0.children ?? [] }
        let other = children.filter { $0.role != "toolbar" }
            .flatMap { ($0.role == "other" || $0.role == nil) && $0.type == .folder ? ($0.children ?? []) : [$0] }
        let title = L("import.bookmarksFolder", browser)
        if !toolbar.isEmpty { add(.folder(title, toolbar), parent: "bar") }
        if !other.isEmpty { add(.folder(title, other), parent: "other") }
        return ops
    }
}
