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

    var isFolder: Bool { kind == .folder }

    var displayTitle: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if !title.isEmpty { return title }
        if let host = URL(string: url)?.host { return host }
        return url.isEmpty ? "New Tab" : url
    }

    var allTabs: [SidebarItem] {
        isFolder ? children.flatMap(\.allTabs) : [self]
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

    var allTabs: [SidebarItem] { pinned.flatMap(\.allTabs) + today }

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
}

final class AppState: Codable {
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

    var spaces: [Space]
    var currentSpaceID: UUID
    var sidebarWidth: Double
    var sidebarHidden: Bool
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

    var currentSpace: Space {
        spaces.first { $0.id == currentSpaceID } ?? spaces[0]
    }

    func space(containing item: SidebarItem) -> Space? {
        spaces.first { $0.find(item.id) === item }
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
