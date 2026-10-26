import AppKit
import ArchideaCore

/// Where a sidebar item being dragged lands in the list, and how that's drawn: worked out from the pointer over the
/// outline and the space's lists, with nothing kept between calls.
struct SidebarDrop {
    struct Target {
        let container: Space.Slot
        let index: Int
        /// Into a folder as a whole (it lights up), not at a line between rows.
        var onto = false
    }

    let outline: NSOutlineView
    let space: Space

    /// Where a drop lands, from the pointer's height alone. AppKit's own proposal also reads how far right the
    /// pointer is to pick a nesting level, so with the pointer mid-row a group fell into the group above, nothing
    /// could go above the top group, and a tab let go below the list went to the top of the pins.
    /// - a tab's upper half drops before it, its lower half after it (the last child of a folder stays inside);
    /// - a folder's top quarter drops before it, its bottom quarter after it (or first inside it when open),
    ///   the middle drops into it;
    /// - the divider's upper half ends the pins, everything below it is Today; empty space below the list is the
    ///   end of Today, above the first row the start of the pins.
    func target(at pointInWindow: NSPoint, moving: SidebarItem) -> Target? {
        let point = outline.convert(pointInWindow, from: nil)
        let row = outline.row(at: point)
        var target: Target
        if row < 0 {
            let first = outline.numberOfRows > 0 ? outline.rect(ofRow: 0) : .zero
            target = point.y < first.minY ? Target(container: .pinned, index: 0) : Target(container: .today, index: space.today.count)
        } else {
            let rect = outline.rect(ofRow: row)
            let fraction = (point.y - rect.minY) / max(rect.height, 1)
            switch outline.item(atRow: row) {
            case let marker as SidebarMarker:
                target = marker.kind == .divider && fraction < 0.5
                    ? Target(container: .pinned, index: space.pinned.count) : Target(container: .today, index: 0)
            case let folder as SidebarItem where folder.isFolder:
                guard let around = space.slot(of: folder), let index = space.location(of: folder)?.index else { return nil }
                let open = outline.isItemExpanded(folder) && !folder.children.isEmpty
                if fraction < 0.25 {
                    target = Target(container: around, index: index)
                } else if fraction > 0.75 {
                    target = open ? Target(container: .folder(folder), index: 0) : Target(container: around, index: index + 1)
                } else {
                    target = Target(container: .folder(folder), index: folder.children.count, onto: true)
                }
            case let item as SidebarItem:
                guard let around = space.slot(of: item), let index = space.location(of: item)?.index else { return nil }
                target = Target(container: around, index: fraction < 0.5 ? index : index + 1)
            default:
                return nil
            }
        }
        if case let .folder(folder) = target.container, space.contains(moving, descendant: folder) { return nil }
        return target
    }


    /// The outline's own (parent, child index) for a model position, so AppKit draws the line in the right place.
    func outlinePosition(_ container: Space.Slot, _ index: Int) -> (SidebarItem?, Int) {
        switch container {
        case .pinned: return (nil, index)
        case .today: return (nil, space.pinned.count + 2 + index)
        case let .folder(folder): return (folder, index)
        }
    }

    /// The last row showing `item` or anything inside it.
    private func lastRow(of item: SidebarItem) -> Int {
        var row = outline.row(forItem: item)
        if item.isFolder, outline.isItemExpanded(item), let last = item.children.last { row = max(row, lastRow(of: last)) }
        return row
    }

    /// The drop line: its height between rows and how far it's indented, in the outline's coordinates.
    func line(for target: Target) -> (y: CGFloat, level: Int)? {
        guard !target.onto else { return nil }
        let items: [SidebarItem]
        let level: Int
        switch target.container {
        case .pinned: (items, level) = (space.pinned, 0)
        case .today: (items, level) = (space.today, 0)
        case let .folder(folder): (items, level) = (folder.children, outline.level(forItem: folder) + 1)
        }
        let y: CGFloat
        if target.index < items.count {
            y = outline.rect(ofRow: outline.row(forItem: items[target.index])).minY
        } else if let last = items.last {
            // The end of a group sits just inside its frame rather than on the frame's edge.
            y = outline.rect(ofRow: lastRow(of: last)).maxY - (level > 0 ? 5 : 0)
        } else if case let .folder(folder) = target.container {
            y = outline.rect(ofRow: outline.row(forItem: folder)).maxY
        } else if case .pinned = target.container {
            y = outline.rect(ofRow: outline.row(forItem: SidebarMarker.divider)).minY
        } else {
            y = outline.rect(ofRow: outline.row(forItem: SidebarMarker.newTab)).maxY
        }
        return (y, min(level, 3))
    }

    /// The group a drop goes into, from its folder's row to its last row, so "into this group" is plain to see.
    func group(for target: Target) -> NSRect? {
        guard case let .folder(folder) = target.container else { return nil }
        let first = outline.row(forItem: folder)
        guard first >= 0 else { return nil }
        let top = outline.rect(ofRow: first)
        let bottom = outline.rect(ofRow: lastRow(of: folder))
        let indent = CGFloat(min(outline.level(forItem: folder), 3)) * outline.indentationPerLevel
        return NSRect(x: indent + 6, y: top.minY + 1, width: outline.bounds.width - indent - 12, height: bottom.maxY - top.minY - 2)
    }

}
