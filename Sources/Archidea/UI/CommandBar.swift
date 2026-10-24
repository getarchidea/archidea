import AppKit
import ArchideaCore

/// ⌘T opens a new tab, ⌘L edits the current one. It lives inside the window, so the window keeps focus.
final class CommandBar: NSView, NSTextFieldDelegate {
    enum Suggestion {
        case open(String)
        case search(String)
        case tab(SidebarItem, space: String?)
        case history(url: String, title: String)

        var url: String? {
            switch self {
            case let .open(url), let .history(url, _): url
            case let .tab(item, _): item.url
            case .search: nil
            }
        }
    }

    private weak var controller: BrowserWindowController?
    /// Dims the page behind the centred bar, so the card reads as lifted off it on a dark page too.
    private let scrim = NSView()
    private let shadowHost = NSView()
    private let card = NSView()
    private let glyph = NSImageView()
    private let field = NSTextField()
    private let separator = NSView()
    private var rows: [SuggestionRow] = []
    private var suggestions: [Suggestion] = []
    private var selected = -1
    private var editing = false
    private var current: String?
    /// Set when editing from the sidebar's address: the bar opens in place over it, compact, like Arc.
    private var anchor: NSRect?
    /// The start page's search field, when the bar opens from it: the bar takes its place, at its width.
    private var over: NSRect?

    private struct Metrics {
        let fieldHeight: CGFloat, rowHeight: CGFloat, fontSize: CGFloat, glyph: CGFloat, radius: CGFloat
        static let centered = Metrics(fieldHeight: 60, rowHeight: 44, fontSize: 20, glyph: 16, radius: 14)
        static let anchored = Metrics(fieldHeight: 46, rowHeight: 40, fontSize: 15, glyph: 13, radius: 12)
    }

    private var metrics: Metrics { anchor == nil ? .centered : .anchored }

    var isOpen: Bool { superview != nil }

    init(controller: BrowserWindowController) {
        self.controller = controller
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]

        scrim.wantsLayer = true
        addSubview(scrim)

        shadowHost.wantsLayer = true
        shadowHost.layer?.shadowColor = NSColor.black.cgColor
        shadowHost.layer?.shadowOffset = CGSize(width: 0, height: -16)
        addSubview(shadowHost)

        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1
        shadowHost.addSubview(card)

        glyph.contentTintColor = .secondaryLabelColor
        card.addSubview(glyph)

        field.font = .systemFont(ofSize: 20, weight: .regular)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.usesSingleLineMode = true
        card.addSubview(field)

        separator.wantsLayer = true
        card.addSubview(separator)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        // Black on a near-black page barely shows, so dark windows get a deeper shadow and a lighter edge.
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        scrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(dark ? 0.32 : 0.12).cgColor
        shadowHost.layer?.shadowOpacity = dark ? 0.7 : 0.28
        shadowHost.layer?.shadowRadius = dark ? 40 : 32
        card.layer?.backgroundColor = Theme.panel.cgColor
        card.layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.13) : NSColor.black.withAlphaComponent(0.1)).cgColor
        separator.layer?.backgroundColor = Theme.hairline.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    /// Opens with `text` already typed (keys pressed on the start page).
    func show(in host: NSView, typing text: String, over searchField: NSRect?) {
        show(in: host, editing: false, current: nil, over: searchField)
        field.stringValue = text
        field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        refresh()
    }

    func show(in host: NSView, editing: Bool, current: String?, anchor: NSRect? = nil, over searchField: NSRect? = nil) {
        self.editing = editing
        self.anchor = anchor
        over = anchor == nil ? searchField : nil
        controller?.history.refresh { [weak self] in
            guard let self, superview != nil, !field.stringValue.isEmpty else { return }
            refresh()
        }
        self.current = current == "about:blank" ? nil : current
        field.stringValue = self.current ?? ""
        let font = NSFont.systemFont(ofSize: metrics.fontSize)
        field.font = font
        let placeholder = editing ? L("command.placeholder.edit") : L("command.placeholder")
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor, .font: font,
        ])
        card.layer?.cornerRadius = metrics.radius
        let opening = superview == nil
        frame = host.bounds
        if opening { host.addSubview(self) }
        refresh()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        if opening {
            shadowHost.alphaValue = 0
            scrim.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                shadowHost.animator().alphaValue = 1
                scrim.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard isOpen else { return }
        removeFromSuperview()
        controller?.commandBarDidHide()
    }

    override func mouseDown(with event: NSEvent) {
        if !shadowHost.frame.contains(convert(event.locationInWindow, from: nil)) { hide() }
    }

    /// Outside the card the sidebar stays reachable: its presses go straight to it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !shadowHost.frame.contains(local), controller?.sidebarTakesPress(at: convert(local, to: nil)) == true { return nil }
        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        let m = metrics
        let listHeight = rows.isEmpty ? 0 : CGFloat(rows.count) * m.rowHeight + 12
        let height = m.fieldHeight + listHeight
        if let anchor {
            let x = max(4, anchor.minX - 4)
            let width = min(max(anchor.width + 8, 400), bounds.width - x - 8)
            shadowHost.frame = NSRect(x: x, y: anchor.maxY + 4 - height, width: width, height: height)
        } else if let over {
            let top = over.maxY + (m.fieldHeight - over.height) / 2
            shadowHost.frame = NSRect(x: over.minX, y: top - height, width: over.width, height: height)
        } else {
            let width = min(660, bounds.width - 64)
            let top = bounds.height - max(60, bounds.height * 0.2)
            shadowHost.frame = NSRect(x: (bounds.width - width) / 2, y: top - height, width: width, height: height)
        }
        // The anchored bar edits the address in place over the sidebar: no dimming there.
        scrim.frame = anchor == nil ? (controller?.pageFrame(in: self) ?? .zero) : .zero
        let width = shadowHost.frame.width
        shadowHost.layer?.shadowPath = CGPath(roundedRect: shadowHost.bounds, cornerWidth: m.radius, cornerHeight: m.radius, transform: nil)
        card.frame = shadowHost.bounds
        let fieldTop = height - m.fieldHeight
        let lineHeight = ceil(m.fontSize * 1.35)
        glyph.frame = NSRect(x: 16, y: fieldTop + (m.fieldHeight - 18) / 2, width: 18, height: 18)
        field.frame = NSRect(x: 44, y: fieldTop + (m.fieldHeight - lineHeight) / 2, width: width - 60, height: lineHeight)
        separator.frame = NSRect(x: 0, y: fieldTop, width: width, height: 1)
        separator.isHidden = rows.isEmpty
        var y = fieldTop - 6 - m.rowHeight
        for row in rows {
            row.frame = NSRect(x: 6, y: y, width: width - 12, height: m.rowHeight)
            y -= m.rowHeight
        }
    }

    // MARK: suggestions

    private func refresh() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var list: [Suggestion] = []
        let unchanged = editing && field.stringValue == (current ?? "")
        if !text.isEmpty, !unchanged {
            list.append(URLInput.isSearch(text) ? .search(text) : .open(URLInput.resolve(text)))
        }
        let browsing = text.isEmpty || unchanged
        let tabs = matchingTabs(browsing ? "" : text.lowercased(), limit: browsing ? 5 : 4)
        list += tabs
        if !browsing, let history = controller?.history {
            // Sites visited before, besides the open and pinned tabs already listed.
            var shown = Set(tabs.compactMap { suggestion -> String? in
                if case let .tab(item, _) = suggestion { return item.url }
                return nil
            })
            if case let .open(url)? = list.first { shown.insert(url) }
            list += history.matches(text, excluding: shown, limit: 8 - list.count).map { .history(url: $0.url, title: $0.title) }
        }
        suggestions = list
        selected = text.isEmpty || unchanged ? -1 : 0
        glyph.image = NSImage(systemSymbolName: URLInput.isSearch(text) || text.isEmpty ? "magnifyingglass" : "globe",
                              accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: metrics.glyph, weight: .semibold))

        rows.forEach { $0.removeFromSuperview() }
        rows = suggestions.enumerated().map { index, suggestion in
            let row = SuggestionRow(suggestion: suggestion, favicon: favicon(for: suggestion))
            row.onClick = { [weak self] in self?.run(index) }
            row.onHover = { [weak self] in self?.select(index) }
            card.addSubview(row)
            return row
        }
        highlight()
        needsLayout = true
    }

    private func matchingTabs(_ query: String, limit: Int) -> [Suggestion] {
        guard let controller else { return [] }
        let active = controller.activeItem
        var found: [(SidebarItem, Space)] = []
        for space in controller.state.spaces {
            for item in space.allTabs where item !== active {
                if query.isEmpty ? space === controller.space
                    : item.displayTitle.lowercased().contains(query) || item.url.lowercased().contains(query) {
                    found.append((item, space))
                }
            }
        }
        if query.isEmpty { found.sort { $0.0.lastActive > $1.0.lastActive } }
        return found.prefix(limit).map { .tab($0.0, space: $0.1 === controller.space ? nil : $0.1.name) }
    }

    private func favicon(for suggestion: Suggestion) -> NSImage? {
        switch suggestion {
        case let .tab(item, _): return controller?.sidebarFavicon(for: item)
        case let .history(url, _), let .open(url):
            if let image = Favicons.shared.cached(url) { return image }
            Favicons.shared.lookUp(url) { [weak self] image in
                guard let self, let index = suggestions.firstIndex(where: { $0.url == url }), rows.indices.contains(index) else { return }
                rows[index].setFavicon(image)
            }
            return nil
        case .search: return nil
        }
    }

    private func select(_ index: Int) {
        selected = index
        highlight()
    }

    private func highlight() {
        for (index, row) in rows.enumerated() { row.highlighted = index == selected }
    }

    private func run(_ index: Int) {
        guard index >= 0, index < suggestions.count, let controller else { return }
        let suggestion = suggestions[index]
        hide()
        switch suggestion {
        case let .open(url): editing ? controller.navigate(url) : controller.openInNewTab(url)
        case let .search(query): editing ? controller.navigate(query) : controller.openInNewTab(query)
        case let .tab(item, _): controller.select(item, cause: "command-bar")
        case let .history(url, _): editing ? controller.navigate(url) : controller.openInNewTab(url)
        }
    }

    #if DRIFT_DEV
    func debugType(_ text: String) {
        field.stringValue = text
        field.currentEditor()?.selectedRange = NSRange(location: text.count, length: 0)
        refresh()
    }
    #endif

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            if !rows.isEmpty { select(min(selected + 1, rows.count - 1)) }
        case #selector(NSResponder.moveUp(_:)):
            if !rows.isEmpty { select(max(selected - 1, 0)) }
        case #selector(NSResponder.insertNewline(_:)):
            if selected >= 0 { run(selected) } else if editing { hide() }
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
        default:
            return false
        }
        return true
    }
}

private final class SuggestionRow: NSView {
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    var highlighted = false {
        didSet {
            needsDisplay = true
            let strong = highlighted
            title.textColor = strong ? .white : .labelColor
            detail.textColor = strong ? .white.withAlphaComponent(0.75) : .secondaryLabelColor
            hint.textColor = strong ? .white : .tertiaryLabelColor
            if usesSymbol { icon.contentTintColor = strong ? .white : .secondaryLabelColor }
            arrow.contentTintColor = strong ? .controlAccentColor : .secondaryLabelColor
            arrowChip.layer?.backgroundColor = (strong ? NSColor.white : Theme.keycap).cgColor
        }
    }

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let arrowChip = NSView()
    private let arrow = NSImageView(image: NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)!
        .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))!)
    private var usesSymbol = true

    init(suggestion: CommandBar.Suggestion, favicon: NSImage?) {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 12)
        detail.lineBreakMode = .byTruncatingMiddle
        hint.font = .systemFont(ofSize: 12.5, weight: .semibold)
        hint.alignment = .right
        arrowChip.wantsLayer = true
        arrowChip.layer?.cornerRadius = 5
        arrowChip.addSubview(arrow)
        switch suggestion {
        case let .open(url):
            icon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            title.stringValue = url
            hint.stringValue = L("command.open")
        case let .search(query):
            icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
            title.stringValue = query
            detail.stringValue = L("command.searchWith", URLInput.engine.name)
            hint.stringValue = L("command.search")
        case let .tab(item, space):
            if let favicon { icon.image = favicon; usesSymbol = false } else {
                icon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            }
            title.stringValue = item.displayTitle
            detail.stringValue = URL(string: item.url)?.host ?? item.url
            hint.stringValue = space.map { L("command.tabInSpace", $0) } ?? L("command.switchToTab")
        case let .history(url, name):
            icon.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
            title.stringValue = name.isEmpty ? url : name
            detail.stringValue = url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            hint.stringValue = L("command.open")
        }
        icon.image = icon.image?.withSymbolConfiguration(.init(pointSize: 14, weight: .medium)) ?? icon.image
        [icon, title, detail, hint, arrowChip].forEach(addSubview)
        if let favicon { setFavicon(favicon) }
        highlighted = false
    }

    /// The site's icon in place of the symbol, once known.
    func setFavicon(_ image: NSImage) {
        icon.image = image
        icon.contentTintColor = nil
        usesSymbol = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 14, y: (h - 18) / 2, width: 18, height: 18)
        arrowChip.frame = NSRect(x: bounds.width - 34, y: (h - 22) / 2, width: 22, height: 22)
        arrow.frame = arrowChip.bounds.insetBy(dx: 4, dy: 4)
        let hintWidth = min(170, hint.intrinsicContentSize.width)
        hint.frame = NSRect(x: arrowChip.frame.minX - hintWidth - 10, y: (h - 16) / 2, width: hintWidth, height: 16)
        let textWidth = max(0, hint.frame.minX - 56)
        if detail.stringValue.isEmpty {
            title.frame = NSRect(x: 44, y: (h - 18) / 2, width: textWidth, height: 18)
        } else {
            title.frame = NSRect(x: 44, y: h / 2 - 1, width: textWidth, height: 18)
            detail.frame = NSRect(x: 44, y: h / 2 - 17, width: textWidth, height: 15)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard highlighted else { return }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// What the page area shows when no tab is open.
final class KeyCap: NSView {
    private let keys: String

    init(_ keys: String) {
        self.keys = keys
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.keycap.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let text = NSAttributedString(string: keys, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

