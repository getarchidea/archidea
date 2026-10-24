import AppKit

/// The sidebar's downloads button and the list it opens.
extension BrowserWindowController {
    func sidebarDownloads(from view: NSView) { toggleDownloads() }

    /// ⇧⌘J and the sidebar's button: the downloads list in a popover off the button (or the address, before any
    /// download has shown the button).
    func toggleDownloads() {
        if let open = downloadsPopover, open.isShown { return open.performClose(nil) }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = DownloadsPanel(isPrivate: isPrivate) { [weak self] url in self?.openInNewTab(url) }
        if sidebarTakesPress(at: sidebar.convert(NSPoint(x: sidebar.bounds.midX, y: sidebar.bounds.midY), to: nil)) {
            let anchor: NSView = sidebar.downloadsButton.isHidden ? sidebar.addressAnchor : sidebar.downloadsButton
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: anchor === sidebar.downloadsButton ? .maxY : .maxX)
        } else {
            // With the sidebar away the list hangs from the page's top left corner.
            popover.show(relativeTo: NSRect(x: 24, y: content.bounds.maxY - 8, width: 1, height: 1), of: content, preferredEdge: .minY)
        }
        downloadsPopover = popover
        showDownloadsState()
    }

    func observeDownloads() {
        downloadsObserver = Downloads.shared.observe { [weak self] in self?.showDownloadsState() }
        showDownloadsState()
    }

    func showDownloadsState() {
        let mine = Downloads.shared.items.filter { $0.offTheRecord == isPrivate }
        let active = mine.filter(\.active)
        var progress: Double?
        if !active.isEmpty {
            let total = active.reduce(0) { $0 + max(0, $1.total) }
            progress = active.contains { $0.total <= 0 } || total <= 0 ? -1 : active.reduce(0) { $0 + $1.received } / total
        }
        sidebar.showDownloads(visible: !mine.isEmpty, progress: progress, unseen: Downloads.shared.unseen && downloadsPopover?.isShown != true)
    }
}
