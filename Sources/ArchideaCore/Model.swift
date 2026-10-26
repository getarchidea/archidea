import Foundation

public final class SidebarItem: Codable {
    /// A split is two to four tabs side by side in the window, one row in the sidebar; its `children` are the tabs,
    /// left to right. A version without splits reads one as a folder holding its tabs.
    public enum Kind: String, Codable { case tab, folder, split }

    public let id: UUID
    public var kind: Kind
    public var title: String
    public var url: String
    public var pinnedURL: String?
    public var children: [SidebarItem]
    public var expanded: Bool
    public var lastActive: Date
    /// SF Symbol for a folder; nil shows the plain folder.
    public var icon: String?
    /// A name the user gave the tab; the page's own title no longer shows while it's set.
    public var customTitle: String?
    /// A split's share of the width for each of its tabs, left to right; nil shares it evenly. `paneWidths` is what
    /// the window lays out.
    public var splitWidths: [Double]?
    /// A live folder's source, which it fills itself from (`refresh(with:)`); nil for every other item.
    public var feed: LiveFeed?
    /// The feed entry a live folder's tab came from, so the same one isn't brought in twice.
    public var entryID: String?
    /// Kept only while set, so the file doesn't carry it for every tab.
    private var unreadMark: Bool?
    /// A short name the AI made of the page's title (`SmartTitles`), and the title it was made of: once the page has
    /// another title, it waits for a new one.
    public var shortTitle: String?
    public var shortTitleOf: String?

    /// Whether tabs show their short names (Settings → AI, while connected).
    public static var showsShortTitles = false

    /// The most tabs a split holds.
    public static let splitLimit = 4

    public init(tab url: String, title: String = "") {
        id = UUID()
        kind = .tab
        self.title = title
        self.url = url
        children = []
        expanded = true
        lastActive = Date()
    }

    /// A split of `tabs`, left to right. `Space.makeSplit` puts one in a list.
    public init(split tabs: [SidebarItem]) {
        id = UUID()
        kind = .split
        title = ""
        url = ""
        children = tabs
        expanded = true
        lastActive = tabs.map(\.lastActive).max() ?? Date()
    }

    public init(folder title: String) {
        id = UUID()
        kind = .folder
        self.title = title
        url = ""
        children = []
        expanded = true
        lastActive = Date()
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, url, pinnedURL, children, expanded, lastActive, icon, customTitle, splitWidths, feed, entryID
        case shortTitle, shortTitleOf
        case unreadMark = "unread"
    }

    /// What builds whose splits held two tabs wrote: the first tab's share of the width.
    private enum OlderKeys: String, CodingKey { case splitRatio }

    /// Reads what any version wrote: a field this one doesn't know is skipped, one it lacks takes its default. A value
    /// that is there but doesn't read (a damaged file) still fails, so the file is set aside rather than written over.
    public init(from decoder: Decoder) throws {
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
        splitWidths = try? c.decodeIfPresent([Double].self, forKey: .splitWidths)
        if splitWidths == nil, let ratio = try? decoder.container(keyedBy: OlderKeys.self).decodeIfPresent(Double.self, forKey: .splitRatio) {
            splitWidths = [ratio, 1 - ratio]
        }
        feed = try? c.decodeIfPresent(LiveFeed.self, forKey: .feed)
        entryID = try? c.decodeIfPresent(String.self, forKey: .entryID)
        unreadMark = try? c.decodeIfPresent(Bool.self, forKey: .unreadMark)
        shortTitle = try? c.decodeIfPresent(String.self, forKey: .shortTitle)
        shortTitleOf = try? c.decodeIfPresent(String.self, forKey: .shortTitleOf)
    }

    /// A tab a live folder brought in that hasn't been opened yet.
    public var isUnread: Bool {
        get { unreadMark == true }
        set { unreadMark = newValue ? true : nil }
    }

    /// A folder that fills itself from a feed.
    public var isLive: Bool { isFolder && feed != nil }

    public var isFolder: Bool { kind == .folder }
    public var isSplit: Bool { kind == .split }
    /// A tab of its own (in a split or not), as opposed to a folder or a split.
    public var isTab: Bool { kind == .tab }

    public var displayTitle: String {
        if isSplit { return children.map(\.displayTitle).joined(separator: " · ") }
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if Self.showsShortTitles, let shortTitle, !shortTitle.isEmpty, shortTitleOf == title { return shortTitle }
        if !title.isEmpty { return title }
        if let host = URL(string: url)?.host { return host }
        return url.isEmpty ? "New Tab" : url
    }

    /// How the diagnostic log names the item: never its title or address, which may be private.
    public var traceName: String { "\(kind.rawValue) \(id.uuidString.prefix(8))" }

    public var allTabs: [SidebarItem] {
        isTab ? [self] : children.flatMap(\.allTabs)
    }

    /// Each tab's share of a split's width, left to right, adding up to 1: the shares set, or even ones when none are
    /// (or they don't fit the tabs).
    public var paneWidths: [Double] {
        let count = children.count
        guard count > 0 else { return [] }
        if let widths = splitWidths, widths.count == count, widths.allSatisfy({ $0 > 0 }) {
            let total = widths.reduce(0, +)
            return widths.map { $0 / total }
        }
        return Array(repeating: 1 / Double(count), count: count)
    }

    /// The tab of a split that takes over from `tab` when it leaves: the one to its right, else the one to its left.
    public func nextPane(after tab: SidebarItem) -> SidebarItem? {
        guard let index = children.firstIndex(where: { $0 === tab }) else { return nil }
        if children.indices.contains(index + 1) { return children[index + 1] }
        return index > 0 ? children[index - 1] : nil
    }

    /// A tab among the pins keeps the address it was pinned at, to go back to; a pinned split's tabs all do.
    fileprivate func keepHome() {
        if isSplit { children.forEach { $0.keepHome() } }
        if isTab, pinnedURL == nil { pinnedURL = url }
    }
}

public final class Space: Codable {
    public enum Appearance: String, Codable, CaseIterable { case system, light, dark }

    public let id: UUID
    public var name: String
    public var symbol: String
    public var colorHex: String
    /// How strongly the space colour tints the window, 0…0.6; nil is the default.
    public var tintStrength: Double?
    /// Light or dark window for this space; nil follows the system.
    public var appearance: Appearance?
    public var pinned: [SidebarItem]
    public var today: [SidebarItem]

    public init(name: String, symbol: String, colorHex: String) {
        id = UUID()
        self.name = name
        self.symbol = symbol
        self.colorHex = colorHex
        pinned = []
        today = []
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, symbol, colorHex, tintStrength, appearance, pinned, today
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "square.grid.2x2"
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#7C8CF8"
        tintStrength = try? c.decodeIfPresent(Double.self, forKey: .tintStrength)
        appearance = try? c.decodeIfPresent(Appearance.self, forKey: .appearance)
        pinned = try c.decodeIfPresent([SidebarItem].self, forKey: .pinned) ?? []
        today = try c.decodeIfPresent([SidebarItem].self, forKey: .today) ?? []
    }

    public var allTabs: [SidebarItem] { pinned.flatMap(\.allTabs) + today.flatMap(\.allTabs) }

    public func find(_ id: UUID) -> SidebarItem? {
        func search(_ items: [SidebarItem]) -> SidebarItem? {
            for item in items {
                if item.id == id { return item }
                if let found = search(item.children) { return found }
            }
            return nil
        }
        return search(pinned) ?? search(today)
    }

    /// Whether the item (or the split it's one side of) is among the pins rather than in Today.
    public func isPinned(_ item: SidebarItem) -> Bool {
        let row = row(of: item)
        return !today.contains { $0 === row }
    }

    /// The array (by parent) holding the item: nil parent with `inToday` tells pinned root from today. A split's tab
    /// has the split as its parent, and is in Today when the split is.
    public func location(of item: SidebarItem) -> (parent: SidebarItem?, inToday: Bool, index: Int)? {
        if let index = today.firstIndex(where: { $0 === item }) { return (nil, true, index) }
        if let index = pinned.firstIndex(where: { $0 === item }) { return (nil, false, index) }
        func search(_ container: SidebarItem) -> (SidebarItem, Int)? {
            if let index = container.children.firstIndex(where: { $0 === item }) { return (container, index) }
            for child in container.children where !child.isTab {
                if let found = search(child) { return found }
            }
            return nil
        }
        for root in today where root.isSplit {
            if let (parent, index) = search(root) { return (parent, true, index) }
        }
        for root in pinned where !root.isTab {
            if let (parent, index) = search(root) { return (parent, false, index) }
        }
        return nil
    }

    /// The split `item` is one side of, if it is.
    public func split(containing item: SidebarItem) -> SidebarItem? {
        guard let parent = location(of: item)?.parent, parent.isSplit else { return nil }
        return parent
    }

    /// The sidebar's row for `item`: its split when it's one side of one, else the item itself.
    public func row(of item: SidebarItem) -> SidebarItem { split(containing: item) ?? item }

    /// Takes the item out of its list. A split left with one tab gives way to that tab, in its place; one left with
    /// more keeps their shares of the width, between them.
    @discardableResult
    public func remove(_ item: SidebarItem) -> Bool {
        guard let loc = location(of: item) else { return false }
        if let parent = loc.parent {
            // Taken out of a live folder by hand (closed, or moved elsewhere to keep): it doesn't come back.
            if parent.isLive, let entry = item.entryID { parent.feed?.dismiss(entry) }
            if parent.isSplit, parent.splitWidths != nil {
                var widths = parent.paneWidths
                widths.remove(at: loc.index)
                parent.splitWidths = widths
            }
            parent.children.remove(at: loc.index)
            if parent.isSplit, parent.children.count < 2 { separate(parent) }
        }
        else if loc.inToday { today.remove(at: loc.index) }
        else { pinned.remove(at: loc.index) }
        return true
    }

    /// Puts `tab` beside `anchor`, right after it or (`before`) right before it: into `anchor`'s split while that
    /// has room, else into a new split in `anchor`'s place. `tab` leaves wherever it was in this space; it must be a
    /// tab of its own, not in a split. The tabs then share the width evenly. Returns the split.
    @discardableResult
    public func makeSplit(_ anchor: SidebarItem, with tab: SidebarItem, before: Bool = false) -> SidebarItem? {
        guard anchor !== tab, anchor.isTab, tab.isTab, split(containing: tab) == nil else { return nil }
        if let split = split(containing: anchor) {
            guard split.children.count < SidebarItem.splitLimit else { return nil }
            if location(of: tab) != nil { remove(tab) }
            guard let index = split.children.firstIndex(where: { $0 === anchor }) else { return nil }
            split.children.insert(tab, at: before ? index : index + 1)
            split.splitWidths = nil
            settle(split)
            return split
        }
        if location(of: tab) != nil { remove(tab) }
        guard let loc = location(of: anchor) else { return nil }
        let split = SidebarItem(split: before ? [tab, anchor] : [anchor, tab])
        if let parent = loc.parent { parent.children[loc.index] = split }
        else if loc.inToday { today[loc.index] = split }
        else { pinned[loc.index] = split }
        settle(split)
        return split
    }

    /// A split's tabs follow its list's rule: pinned ones keep a home address, Today ones have none.
    private func settle(_ split: SidebarItem) {
        if location(of: split)?.inToday == true { split.children.forEach { $0.pinnedURL = nil } } else { split.keepHome() }
    }

    /// Breaks a split into its tabs where it was: the first in its place, the others right after it, in order.
    public func separate(_ split: SidebarItem) {
        guard split.isSplit, let loc = location(of: split) else { return }
        let tabs = split.children
        split.children = []
        if let parent = loc.parent { parent.children.replaceSubrange(loc.index...loc.index, with: tabs) }
        else if loc.inToday { today.replaceSubrange(loc.index...loc.index, with: tabs) }
        else { pinned.replaceSubrange(loc.index...loc.index, with: tabs) }
    }

    public func contains(_ ancestor: SidebarItem, descendant: SidebarItem) -> Bool {
        ancestor === descendant || ancestor.children.contains { contains($0, descendant: descendant) }
    }

    /// A list a sidebar item sits in: the pins, Today, or a folder among the pins.
    public enum Slot {
        case pinned, today, folder(SidebarItem)

        public func same(_ other: Slot) -> Bool {
            switch (self, other) {
            case (.pinned, .pinned), (.today, .today): return true
            case let (.folder(a), .folder(b)): return a === b
            default: return false
            }
        }
    }

    public func slot(of item: SidebarItem) -> Slot? {
        guard let loc = location(of: item) else { return nil }
        if let parent = loc.parent, parent.isSplit { return slot(of: parent) }
        return loc.parent.map { .folder($0) } ?? (loc.inToday ? .today : .pinned)
    }

    /// Puts an item that is in no list into `slot` at `index` (clamped). What each list may hold is kept here and
    /// nowhere else: folders live among the pins (one meant for Today joins the end of the pins), a pinned tab has a
    /// home address, a Today tab has none.
    public func place(_ item: SidebarItem, in slot: Slot, at index: Int) {
        func clamped(_ count: Int) -> Int { min(max(index, 0), count) }
        switch slot {
        case .today where item.isFolder:
            pinned.append(item)
        case .today:
            // A tab, or a split's two tabs.
            item.allTabs.forEach { $0.pinnedURL = nil }
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
    public func move(_ item: SidebarItem, to slot: Slot, at index: Int) {
        var at = index
        let source = self.slot(of: item)
        if let from = location(of: item), let source, source.same(slot), from.index < at { at -= 1 }
        remove(item)
        place(item, in: slot, at: at)
        // Moved within its live folder, it was never taken out.
        if source?.same(slot) == true, case let .folder(folder) = slot, let entry = item.entryID {
            folder.feed?.dismissed.removeAll { $0 == entry }
        }
    }

    /// Today tabs untouched since `cutoff`, except those `keep` holds on to.
    public func staleToday(before cutoff: Date, keeping keep: (SidebarItem) -> Bool = { _ in false }) -> [SidebarItem] {
        today.filter { !$0.isFolder && $0.lastActive < cutoff && !keep($0) }
    }
}

/// A tab closed lately, for ⇧⌘T and the start page, with where it was so a pin goes back to its place.
public struct ClosedTab: Codable, Equatable {
    public var url: String
    public var title: String
    public var customTitle: String?
    public var spaceID: UUID
    /// For a pin: its home address, the folder it sat in (nil: the pins themselves) and its position there.
    public var pinnedURL: String?
    public var folderID: UUID?
    public var index: Int?
}

public final class AppState: Codable {
    /// The layout of state.json. Raised when a change needs more than new fields with defaults, so a migration
    /// can tell an old file from a new one. 2: each window's view (`windows`) instead of one current space and
    /// one selected tab per space.
    public static let schemaVersion = 2
    /// How many closed tabs ⇧⌘T can bring back.
    public static let closedLimit = 50

    /// A private window's single dark space.
    public static func privateWindow() -> AppState {
        let state = AppState()
        let space = state.spaces[0]
        space.name = L("private.space")
        space.symbol = "eyeglasses"
        space.colorHex = "#8A8F98"
        space.appearance = .dark
        return state
    }

    public private(set) var version = AppState.schemaVersion
    public var spaces: [Space]
    /// What each browser window shows, the one opened first first. There is always at least one.
    public var windows: [WindowState]
    public var sidebarWidth: Double
    /// Newest last.
    public var recentlyClosed: [ClosedTab] = []
    private var storedSettings: BrowserSettings?

    public var settings: BrowserSettings {
        get { storedSettings ?? BrowserSettings() }
        set { storedSettings = newValue }
    }

    public init() {
        let home = Space(name: "Home", symbol: "house", colorHex: "#7C8CF8")
        spaces = [home]
        windows = [WindowState(spaceID: home.id)]
        sidebarWidth = 248
    }

    private enum CodingKeys: String, CodingKey {
        case version, spaces, windows, sidebarWidth, recentlyClosed, storedSettings
    }

    /// What version 1 kept of its one window: the current space, the sidebar hidden or not, each space's tab in front.
    private enum LegacyKeys: String, CodingKey { case currentSpaceID, sidebarHidden, spaces }
    private struct LegacySpace: Decodable { let id: UUID?, selectedID: UUID? }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Files from before the version was written are version 0; they read like version 1.
        _ = try? c.decodeIfPresent(Int.self, forKey: .version)
        version = Self.schemaVersion
        spaces = try c.decodeIfPresent([Space].self, forKey: .spaces) ?? []
        // The windows only say how the sidebar was looked at: a list that doesn't read costs that, not the sidebar.
        windows = (try? c.decodeIfPresent([WindowState].self, forKey: .windows)) ?? []
        if windows.isEmpty {
            // Version 1 had one window, and kept what it showed with the sidebar itself.
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let window = WindowState(spaceID: (try? legacy.decodeIfPresent(UUID.self, forKey: .currentSpaceID)) ?? spaces.first?.id ?? UUID(),
                                     sidebarHidden: (try? legacy.decodeIfPresent(Bool.self, forKey: .sidebarHidden)) ?? false)
            for old in (try? legacy.decodeIfPresent([LegacySpace].self, forKey: .spaces)) ?? [] {
                guard let id = old.id, let selected = old.selectedID, let space = spaces.first(where: { $0.id == id }) else { continue }
                window.select(selected, in: space)
            }
            windows = [window]
        }
        sidebarWidth = (try? c.decodeIfPresent(Double.self, forKey: .sidebarWidth)) ?? 248
        // Only a convenience: a list that doesn't read is dropped rather than costing the sidebar.
        recentlyClosed = (try? c.decodeIfPresent([ClosedTab].self, forKey: .recentlyClosed)) ?? []
        storedSettings = try? c.decodeIfPresent(BrowserSettings.self, forKey: .storedSettings)
    }

    /// The space `window` shows.
    public func space(shownIn window: WindowState) -> Space {
        spaces.first { $0.id == window.spaceID } ?? spaces[0]
    }

    /// Whether some window has `item` in front in `space` (for a split, either of its tabs): it isn't archived.
    public func isInFront(_ item: SidebarItem, in space: Space) -> Bool {
        windows.contains { window in
            guard let id = window.selectedID(in: space) else { return false }
            return id == item.id || item.allTabs.contains { $0.id == id }
        }
    }

    /// Takes a space out, unless it's the last one; windows that showed it show the first space left.
    public func removeSpace(_ space: Space) {
        guard spaces.count > 1, spaces.contains(where: { $0 === space }) else { return }
        spaces.removeAll { $0 === space }
        for window in windows where window.spaceID == space.id { window.spaceID = spaces[0].id }
    }

    public func space(containing item: SidebarItem) -> Space? {
        spaces.first { $0.find(item.id) === item }
    }

    /// Puts right what an older version (or a bug) may have saved: a folder in Today goes back among the pins, a
    /// split holds two to four tabs, a pinned tab gets its home address, a Today tab loses one, every window shows a space
    /// that exists and there is a window. Returns whether anything changed.
    @discardableResult
    public func repair() -> Bool {
        var changed = false
        for space in spaces {
            let strays = space.today.filter(\.isFolder)
            if !strays.isEmpty {
                space.today.removeAll { $0.isFolder }
                space.pinned += strays
                changed = true
            }
            // A split holds two to four tabs of its own. One holding anything else gives way to the tabs in it.
            func splits(_ items: [SidebarItem]) -> [SidebarItem] {
                items.flatMap { $0.isSplit ? [$0] : $0.isFolder ? splits($0.children) : [] }
            }
            for split in splits(space.today) + splits(space.pinned) {
                if !split.children.allSatisfy(\.isTab) {
                    split.children = split.allTabs
                    changed = true
                }
                if !(2...SidebarItem.splitLimit).contains(split.children.count) {
                    space.separate(split)
                    changed = true
                } else if let widths = split.splitWidths, widths.count != split.children.count {
                    split.splitWidths = nil
                    changed = true
                }
            }
            for item in space.today.flatMap(\.allTabs) where item.pinnedURL != nil {
                item.pinnedURL = nil
                changed = true
            }
            for item in space.pinned.flatMap(\.allTabs) where item.pinnedURL == nil {
                item.pinnedURL = item.url
                changed = true
            }
        }
        guard let first = spaces.first else { return changed }
        if windows.isEmpty {
            windows = [WindowState(spaceID: first.id)]
            changed = true
        }
        for window in windows where !spaces.contains(where: { $0.id == window.spaceID }) {
            window.spaceID = first.id
            changed = true
        }
        return changed
    }

    // MARK: recently closed

    /// Puts a tab that is about to go on the reopen list, with its place when it's a pin. Folders and blank tabs
    /// aren't worth bringing back.
    public func remember(_ item: SidebarItem) {
        if item.isSplit { return item.children.forEach(remember) }
        guard item.isTab, !item.url.isEmpty, item.url != "about:blank", let owner = space(containing: item) else { return }
        var closed = ClosedTab(url: item.url, title: item.title, customTitle: item.customTitle, spaceID: owner.id)
        // A split's tab comes back where its split was.
        if let loc = owner.location(of: owner.row(of: item)), !loc.inToday {
            closed.pinnedURL = item.pinnedURL ?? item.url
            closed.folderID = loc.parent?.id
            closed.index = loc.index
        }
        recentlyClosed.append(closed)
        if recentlyClosed.count > Self.closedLimit { recentlyClosed.removeFirst(recentlyClosed.count - Self.closedLimit) }
    }

    /// Brings the newest closed tab back: a pin to its place (the end of the pins when its folder has gone), anything
    /// else to the top of Today, in its own space while that exists, else in `fallback`. Returns the new item and
    /// the space it went to.
    public func reopenLastClosed(fallback: Space) -> (item: SidebarItem, space: Space)? {
        guard let last = recentlyClosed.popLast() else { return nil }
        let owner = spaces.first { $0.id == last.spaceID } ?? fallback
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
    public func bringForward(closedAt index: Int) -> Bool {
        let position = recentlyClosed.count - 1 - index
        guard recentlyClosed.indices.contains(position) else { return false }
        recentlyClosed.append(recentlyClosed.remove(at: position))
        return true
    }
}

/// Browser-wide preferences. Every field has a default and a missing one decodes to it,
/// so older state files and newer fields keep working.
public struct BrowserSettings: Codable, Equatable {
    public var searchEngine = SearchEngine.google
    /// Today tabs untouched this long are archived; 0 never archives.
    public var archiveHours = 12
    /// Background tabs untouched this long give their memory back; 0 never unloads.
    public var unloadMinutes = 30
    /// Clear keeps Today tabs used within this many minutes, besides the active one and those playing sound.
    public var clearKeepsMinutes = 15
    /// The address bar shows the whole URL instead of the host.
    public var showFullURL = false
    /// The built-in ad and tracker blocker (uBlock Origin).
    public var adBlock = false
    /// Cookie banners answered with "reject all", or hidden where that isn't possible (autoconsent).
    public var hideCookieBanners = true
    /// Where links from other apps open: a mini window of their own, or a tab in the browser window.
    public var linksInMiniWindow = true
    /// The AI features and the service behind them; the key itself is kept apart, never in this file.
    public var ai = AISettings()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BrowserSettings()
        searchEngine = (try? c.decodeIfPresent(SearchEngine.self, forKey: .searchEngine)) ?? defaults.searchEngine
        archiveHours = (try? c.decodeIfPresent(Int.self, forKey: .archiveHours)) ?? defaults.archiveHours
        unloadMinutes = (try? c.decodeIfPresent(Int.self, forKey: .unloadMinutes)) ?? defaults.unloadMinutes
        clearKeepsMinutes = (try? c.decodeIfPresent(Int.self, forKey: .clearKeepsMinutes)) ?? defaults.clearKeepsMinutes
        showFullURL = (try? c.decodeIfPresent(Bool.self, forKey: .showFullURL)) ?? defaults.showFullURL
        adBlock = (try? c.decodeIfPresent(Bool.self, forKey: .adBlock)) ?? defaults.adBlock
        hideCookieBanners = (try? c.decodeIfPresent(Bool.self, forKey: .hideCookieBanners)) ?? defaults.hideCookieBanners
        linksInMiniWindow = (try? c.decodeIfPresent(Bool.self, forKey: .linksInMiniWindow)) ?? defaults.linksInMiniWindow
        ai = (try? c.decodeIfPresent(AISettings.self, forKey: .ai)) ?? defaults.ai
    }
}

public enum SearchEngine: String, Codable, CaseIterable {
    case google, duckduckgo, bing, yandex, kagi, brave, ecosia

    public var name: String {
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

    public var template: String {
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
