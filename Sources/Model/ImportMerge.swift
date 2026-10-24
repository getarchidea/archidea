import Foundation

extension AppState {
    /// Imported spaces join the sidebar (one with the same name takes them in); open tabs go to the current Today.
    /// An untouched starting space is dropped when real ones arrive. Folders only ever land among the pins, wherever
    /// the other browser had them. `symbolExists` says whether an SF Symbol is on this Mac.
    func adopt(imported: [ImportedSpace], openTabs: [ImportedNode],
               symbolExists: (String) -> Bool) -> (spaces: Int, pins: Int, tabs: Int) {
        var counts = (spaces: 0, pins: 0, tabs: 0)
        func symbolIfReal(_ name: String?) -> String? {
            name.flatMap { symbolExists($0) ? $0 : nil }
        }
        func item(_ node: ImportedNode, pinned: Bool) -> SidebarItem? {
            switch node {
            case let .tab(url, title):
                guard !url.isEmpty else { return nil }
                let tab = SidebarItem(tab: url, title: title)
                if pinned { tab.pinnedURL = url }
                return tab
            case let .folder(title, symbol, children, expanded):
                let folder = SidebarItem(folder: title.isEmpty ? L("folder.new") : title)
                folder.icon = symbolIfReal(symbol)
                folder.expanded = expanded
                folder.children = children.compactMap { item($0, pinned: true) }
                return folder
            }
        }
        let starting = currentSpace
        let untouched = spaces.count == 1 && starting.pinned.isEmpty && starting.today.isEmpty
        for incoming in imported where !(incoming.pinned.isEmpty && incoming.tabs.isEmpty) {
            let target: Space
            if let existing = spaces.first(where: { $0.name == incoming.name }), !(untouched && existing === starting) {
                target = existing
            } else {
                let index = spaces.count
                target = Space(name: incoming.name,
                               symbol: symbolIfReal(incoming.symbol) ?? SpaceStyle.symbols[index % SpaceStyle.symbols.count],
                               colorHex: incoming.colorHex ?? SpaceStyle.palette[index % SpaceStyle.palette.count])
                spaces.append(target)
                counts.spaces += 1
            }
            let tabs = incoming.tabs.compactMap { item($0, pinned: false) }
            counts.pins += Self.merge(incoming.pinned.compactMap { item($0, pinned: true) } + tabs.filter(\.isFolder), into: &target.pinned)
            counts.tabs += Self.merge(tabs.filter { !$0.isFolder }, into: &target.today)
        }
        if untouched, counts.spaces > 0, starting.pinned.isEmpty, starting.today.isEmpty, openTabs.isEmpty {
            spaces.removeAll { $0 === starting }
            currentSpaceID = spaces[0].id
        }
        let current = currentSpace
        let open = openTabs.compactMap { item($0, pinned: false) }
        counts.pins += Self.merge(open.filter(\.isFolder), into: &current.pinned)
        var fresh: [SidebarItem] = []
        counts.tabs += Self.merge(open.filter { !$0.isFolder }, into: &fresh, skipping: current.allTabs)
        current.today.insert(contentsOf: fresh, at: 0)
        return counts
    }

    /// Adds `incoming` to `items` the way a second import of the same browser should: a tab whose address is
    /// already there (or in `skipping`) is left out, a folder of the same name takes the new children.
    /// Returns how many tabs were added.
    static func merge(_ incoming: [SidebarItem], into items: inout [SidebarItem], skipping: [SidebarItem] = []) -> Int {
        var known = Set((items.flatMap(\.allTabs) + skipping).map { $0.pinnedURL ?? $0.url })
        var added = 0
        for item in incoming {
            if item.isFolder {
                if let folder = items.first(where: { $0.isFolder && $0.title == item.title }) {
                    added += merge(item.children, into: &folder.children)
                } else {
                    item.children.removeAll { !$0.isFolder && !known.insert($0.pinnedURL ?? $0.url).inserted }
                    added += item.allTabs.count
                    items.append(item)
                }
            } else if known.insert(item.pinnedURL ?? item.url).inserted {
                items.append(item)
                added += 1
            }
        }
        return added
    }
}
