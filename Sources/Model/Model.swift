import Foundation

final class SidebarItem: Codable {
    enum Kind: String, Codable { case tab, folder }

    let id: UUID
    var kind: Kind
    var title: String
    var url: String
    var pinnedURL: String?
    var children: [SidebarItem]
    var expanded: Bool
    var lastActive: Date
    /// SF Symbol for a folder; nil shows the plain folder.
    var icon: String?
    /// A name the user gave the tab; the page's own title no longer shows while it's set.
    var customTitle: String?

    init(tab url: String, title: String = "") {
        id = UUID()
        kind = .tab
        self.title = title
        self.url = url
        children = []
        expanded = true
        lastActive = Date()
    }

    init(folder title: String) {
        id = UUID()
        kind = .folder
        self.title = title
        url = ""
        children = []
        expanded = true
        lastActive = Date()
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, url, pinnedURL, children, expanded, lastActive, icon, customTitle
    }

    /// Reads what any version wrote: a field this one doesn't know is skipped, one it lacks takes its default. A value
    /// that is there but doesn't read (a damaged file) still fails, so the file is set aside rather than written over.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        children = try c.decodeIfPresent([SidebarItem].self, forKey: .children) ?? []
        // A kind from a newer version reads as what it holds.
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? (children.isEmpty ? .tab : .folder)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        pinnedURL = try c.decodeIfPresent(String.self, forKey: .pinnedURL)
        expanded = try c.decodeIfPresent(Bool.self, forKey: .expanded) ?? true
        lastActive = try c.decodeIfPresent(Date.self, forKey: .lastActive) ?? Date()
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
    }

    var isFolder: Bool { kind == .folder }

    var displayTitle: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if !title.isEmpty { return title }
        if let host = URL(string: url)?.host { return host }
        return url.isEmpty ? "New Tab" : url
    }

    /// How the diagnostic log names the item: never its title or address, which may be private.
    var traceName: String { "\(kind.rawValue) \(id.uuidString.prefix(8))" }

    var allTabs: [SidebarItem] {
        isFolder ? children.flatMap(\.allTabs) : [self]
    }

    /// A tab among the pins keeps the address it was pinned at, to go back to.
    fileprivate func keepHome() {
        if !isFolder, pinnedURL == nil { pinnedURL = url }
    }
}

final class Space: Codable {
    enum Appearance: String, Codable, CaseIterable { case system, light, dark }

    let id: UUID
    var name: String
    var symbol: String
    var colorHex: String
    /// How strongly the space colour tints the window, 0…0.6; nil is the default.
    var tintStrength: Double?
    /// Light or dark window for this space; nil follows the system.
    var appearance: Appearance?
    var pinned: [SidebarItem]
    var today: [SidebarItem]
    var selectedID: UUID?

    init(name: String, symbol: String, colorHex: String) {
        id = UUID()
        self.name = name
        self.symbol = symbol
        self.colorHex = colorHex
        pinned = []
        today = []
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, symbol, colorHex, tintStrength, appearance, pinned, today, selectedID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "square.grid.2x2"
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#7C8CF8"
        tintStrength = try? c.decodeIfPresent(Double.self, forKey: .tintStrength)
        appearance = try? c.decodeIfPresent(Appearance.self, forKey: .appearance)
        pinned = try c.decodeIfPresent([SidebarItem].self, forKey: .pinned) ?? []
        today = try c.decodeIfPresent([SidebarItem].self, forKey: .today) ?? []
        selectedID = try? c.decodeIfPresent(UUID.self, forKey: .selectedID)
    }

    var allTabs: [SidebarItem] { pinned.flatMap(\.allTabs) + today.flatMap(\.allTabs) }

    func find(_ id: UUID) -> SidebarItem? {
        func search(_ items: [SidebarItem]) -> SidebarItem? {
            for item in items {
                if item.id == id { return item }
                if let found = search(item.children) { return found }
            }
            return nil
        }
        return search(pinned) ?? search(today)
    }

    func isPinned(_ item: SidebarItem) -> Bool {
        !today.contains { $0 === item }
    }

    /// The array (by parent) holding the item: nil parent with `inToday` tells pinned root from today.
    func location(of item: SidebarItem) -> (parent: SidebarItem?, inToday: Bool, index: Int)? {
        if let index = today.firstIndex(where: { $0 === item }) { return (nil, true, index) }
        if let index = pinned.firstIndex(where: { $0 === item }) { return (nil, false, index) }
        func search(_ folder: SidebarItem) -> (SidebarItem, Int)? {
            if let index = folder.children.firstIndex(where: { $0 === item }) { return (folder, index) }
            for child in folder.children where child.isFolder {
                if let found = search(child) { return found }
            }
            return nil
        }
        for root in pinned where root.isFolder {
            if let (parent, index) = search(root) { return (parent, false, index) }
        }
        return nil
    }

    @discardableResult
    func remove(_ item: SidebarItem) -> Bool {
        guard let loc = location(of: item) else { return false }
        if let parent = loc.parent { parent.children.remove(at: loc.index) }
        else if loc.inToday { today.remove(at: loc.index) }
        else { pinned.remove(at: loc.index) }
        return true
    }

    func contains(_ ancestor: SidebarItem, descendant: SidebarItem) -> Bool {
        ancestor === descendant || ancestor.children.contains { contains($0, descendant: descendant) }
    }

    /// A list a sidebar item sits in: the pins, Today, or a folder among the pins.
    enum Slot {
        case pinned, today, folder(SidebarItem)

        func same(_ other: Slot) -> Bool {
            switch (self, other) {
            case (.pinned, .pinned), (.today, .today): return true
            case let (.folder(a), .folder(b)): return a === b
            default: return false
            }
        }
    }

    func slot(of item: SidebarItem) -> Slot? {
        guard let loc = location(of: item) else { return nil }
        return loc.parent.map { .folder($0) } ?? (loc.inToday ? .today : .pinned)
    }

    /// Puts an item that is in no list into `slot` at `index` (clamped). What each list may hold is kept here and
    /// nowhere else: folders live among the pins (one meant for Today joins the end of the pins), a pinned tab has a
    /// home address, a Today tab has none.
    func place(_ item: SidebarItem, in slot: Slot, at index: Int) {
        func clamped(_ count: Int) -> Int { min(max(index, 0), count) }
        switch slot {
        case .today where item.isFolder:
            pinned.append(item)
        case .today:
            item.pinnedURL = nil
            today.insert(item, at: clamped(today.count))
        case .pinned:
            item.keepHome()
            pinned.insert(item, at: clamped(pinned.count))
        case let .folder(folder):
            item.keepHome()
            folder.children.insert(item, at: clamped(folder.children.count))
            folder.expanded = true
        }
    }

    /// Takes `item` out of wherever it is in this space and puts it into `slot`. An index counts positions as they
    /// were before the move, so moving down within one list lands where it was let go.
    func move(_ item: SidebarItem, to slot: Slot, at index: Int) {
        var at = index
        if let from = location(of: item), let source = self.slot(of: item), source.same(slot), from.index < at { at -= 1 }
        remove(item)
        place(item, in: slot, at: at)
    }

    /// Today tabs untouched since `cutoff`, except those `keep` holds on to.
    func staleToday(before cutoff: Date, keeping keep: (SidebarItem) -> Bool = { _ in false }) -> [SidebarItem] {
        today.filter { !$0.isFolder && $0.lastActive < cutoff && !keep($0) }
    }
}

/// A tab closed lately, for ⇧⌘T and the start page, with where it was so a pin goes back to its place.
struct ClosedTab: Codable, Equatable {
    var url: String
    var title: String
    var customTitle: String?
    var spaceID: UUID
    /// For a pin: its home address, the folder it sat in (nil: the pins themselves) and its position there.
    var pinnedURL: String?
    var folderID: UUID?
    var index: Int?
}

final class AppState: Codable {
    /// The layout of state.json. Raised when a change needs more than new fields with defaults, so a migration
    /// can tell an old file from a new one.
    static let schemaVersion = 1
    /// How many closed tabs ⇧⌘T can bring back.
    static let closedLimit = 50

    /// A private window's single dark space.
    static func privateWindow() -> AppState {
        let state = AppState()
        let space = state.spaces[0]
        space.name = L("private.space")
        space.symbol = "eyeglasses"
        space.colorHex = "#8A8F98"
        space.appearance = .dark
        return state
    }

    private(set) var version = AppState.schemaVersion
    var spaces: [Space]
    var currentSpaceID: UUID
    var sidebarWidth: Double
    var sidebarHidden: Bool
    /// Newest last.
    var recentlyClosed: [ClosedTab] = []
    private var storedSettings: BrowserSettings?

    var settings: BrowserSettings {
        get { storedSettings ?? BrowserSettings() }
        set { storedSettings = newValue }
    }

    init() {
        let home = Space(name: "Home", symbol: "house", colorHex: "#7C8CF8")
        spaces = [home]
        currentSpaceID = home.id
        sidebarWidth = 248
        sidebarHidden = false
    }

    private enum CodingKeys: String, CodingKey {
        case version, spaces, currentSpaceID, sidebarWidth, sidebarHidden, recentlyClosed, storedSettings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Files from before the version was written are version 0; nothing needs migrating from it yet.
        _ = try? c.decodeIfPresent(Int.self, forKey: .version)
        version = Self.schemaVersion
        spaces = try c.decodeIfPresent([Space].self, forKey: .spaces) ?? []
        currentSpaceID = (try? c.decodeIfPresent(UUID.self, forKey: .currentSpaceID)) ?? spaces.first?.id ?? UUID()
        sidebarWidth = (try? c.decodeIfPresent(Double.self, forKey: .sidebarWidth)) ?? 248
        sidebarHidden = (try? c.decodeIfPresent(Bool.self, forKey: .sidebarHidden)) ?? false
        // Only a convenience: a list that doesn't read is dropped rather than costing the sidebar.
        recentlyClosed = (try? c.decodeIfPresent([ClosedTab].self, forKey: .recentlyClosed)) ?? []
        storedSettings = try? c.decodeIfPresent(BrowserSettings.self, forKey: .storedSettings)
    }

    var currentSpace: Space {
        spaces.first { $0.id == currentSpaceID } ?? spaces[0]
    }

    func space(containing item: SidebarItem) -> Space? {
        spaces.first { $0.find(item.id) === item }
    }

    /// Puts right what an older version (or a bug) may have saved: a folder in Today goes back among the pins, a
    /// pinned tab gets its home address, a Today tab loses one, the current space is one that exists.
    /// Returns whether anything changed.
    @discardableResult
    func repair() -> Bool {
        var changed = false
        for space in spaces {
            let strays = space.today.filter(\.isFolder)
            if !strays.isEmpty {
                space.today.removeAll { $0.isFolder }
                space.pinned += strays
                changed = true
            }
            for item in space.today where item.pinnedURL != nil {
                item.pinnedURL = nil
                changed = true
            }
            for item in space.pinned.flatMap(\.allTabs) where item.pinnedURL == nil {
                item.pinnedURL = item.url
                changed = true
            }
        }
        if !spaces.contains(where: { $0.id == currentSpaceID }), let first = spaces.first {
            currentSpaceID = first.id
            changed = true
        }
        return changed
    }

    // MARK: recently closed

    /// Puts a tab that is about to go on the reopen list, with its place when it's a pin. Folders and blank tabs
    /// aren't worth bringing back.
    func remember(_ item: SidebarItem) {
        guard !item.isFolder, !item.url.isEmpty, item.url != "about:blank", let owner = space(containing: item) else { return }
        var closed = ClosedTab(url: item.url, title: item.title, customTitle: item.customTitle, spaceID: owner.id)
        if let loc = owner.location(of: item), !loc.inToday {
            closed.pinnedURL = item.pinnedURL ?? item.url
            closed.folderID = loc.parent?.id
            closed.index = loc.index
        }
        recentlyClosed.append(closed)
        if recentlyClosed.count > Self.closedLimit { recentlyClosed.removeFirst(recentlyClosed.count - Self.closedLimit) }
    }

    /// Brings the newest closed tab back: a pin to its place (the end of the pins when its folder has gone), anything
    /// else to the top of Today, in its own space while that exists. Returns the new item and the space it went to.
    func reopenLastClosed() -> (item: SidebarItem, space: Space)? {
        guard let last = recentlyClosed.popLast() else { return nil }
        let owner = spaces.first { $0.id == last.spaceID } ?? currentSpace
        let item = SidebarItem(tab: last.url, title: last.title)
        item.customTitle = last.customTitle
        if let home = last.pinnedURL {
            item.pinnedURL = home
            let folder = last.folderID.flatMap { owner.find($0) }.flatMap { $0.isFolder ? $0 : nil }
            owner.place(item, in: folder.map { Space.Slot.folder($0) } ?? .pinned, at: last.index ?? owner.pinned.count)
        } else {
            owner.place(item, in: .today, at: 0)
        }
        return (item, owner)
    }

    /// Moves the closed tab `index` places from the newest to the end, so it is the one that reopens next.
    func bringForward(closedAt index: Int) -> Bool {
        let position = recentlyClosed.count - 1 - index
        guard recentlyClosed.indices.contains(position) else { return false }
        recentlyClosed.append(recentlyClosed.remove(at: position))
        return true
    }
}

/// Browser-wide preferences. Every field has a default and a missing one decodes to it,
/// so older state files and newer fields keep working.
struct BrowserSettings: Codable, Equatable {
    var searchEngine = SearchEngine.google
    /// Today tabs untouched this long are archived; 0 never archives.
    var archiveHours = 12
    /// Background tabs untouched this long give their memory back; 0 never unloads.
    var unloadMinutes = 30
    /// Clear keeps Today tabs used within this many minutes, besides the active one and those playing sound.
    var clearKeepsMinutes = 15
    /// The address bar shows the whole URL instead of the host.
    var showFullURL = false
    /// The built-in ad and tracker blocker (uBlock Origin).
    var adBlock = false
    /// Where links from other apps open: a mini window of their own, or a tab in the browser window.
    var linksInMiniWindow = true
    /// Sites taken off the start page.
    var hiddenTopSites: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BrowserSettings()
        searchEngine = (try? c.decodeIfPresent(SearchEngine.self, forKey: .searchEngine)) ?? defaults.searchEngine
        archiveHours = (try? c.decodeIfPresent(Int.self, forKey: .archiveHours)) ?? defaults.archiveHours
        unloadMinutes = (try? c.decodeIfPresent(Int.self, forKey: .unloadMinutes)) ?? defaults.unloadMinutes
        clearKeepsMinutes = (try? c.decodeIfPresent(Int.self, forKey: .clearKeepsMinutes)) ?? defaults.clearKeepsMinutes
        showFullURL = (try? c.decodeIfPresent(Bool.self, forKey: .showFullURL)) ?? defaults.showFullURL
        adBlock = (try? c.decodeIfPresent(Bool.self, forKey: .adBlock)) ?? defaults.adBlock
        linksInMiniWindow = (try? c.decodeIfPresent(Bool.self, forKey: .linksInMiniWindow)) ?? defaults.linksInMiniWindow
        hiddenTopSites = (try? c.decodeIfPresent([String].self, forKey: .hiddenTopSites)) ?? defaults.hiddenTopSites
    }
}

enum SearchEngine: String, Codable, CaseIterable {
    case google, duckduckgo, bing, yandex, kagi, brave, ecosia

    var name: String {
        switch self {
        case .google: return "Google"
        case .duckduckgo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .yandex: return L("search.yandex")
        case .kagi: return "Kagi"
        case .brave: return "Brave Search"
        case .ecosia: return "Ecosia"
        }
    }

    var template: String {
        switch self {
        case .google: return "https://www.google.com/search?q=%@"
        case .duckduckgo: return "https://duckduckgo.com/?q=%@"
        case .bing: return "https://www.bing.com/search?q=%@"
        case .yandex: return "https://yandex.ru/search/?text=%@"
        case .kagi: return "https://kagi.com/search?q=%@"
        case .brave: return "https://search.brave.com/search?q=%@"
        case .ecosia: return "https://www.ecosia.org/search?q=%@"
        }
    }
}
