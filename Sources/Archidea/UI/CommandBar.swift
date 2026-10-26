import AppKit
import ArchideaCore

/// ⌘T opens a new tab, ⌘L edits the current one. It lives inside the window, so the window keeps focus.
final class CommandBar: NSView, NSTextFieldDelegate {
    enum Suggestion {
        case open(String)
        case search(String)
        /// Asks the AI connected in Settings; the answer shows in the bar.
        case ask(String)
        case tab(SidebarItem, space: String?)
        case history(url: String, title: String)

        var url: String? {
            switch self {
            case let .open(url), let .history(url, _): url
            case let .tab(item, _): item.url
            case .search, .ask: nil
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
    /// The conversation with the AI, in place of the suggestions, once a question is asked; the field then takes
    /// follow-up questions.
    private var answer: ChatView?
    private var answering: Task<Void, Never>?

    private struct Metrics {
        let fieldHeight: CGFloat, rowHeight: CGFloat, fontSize: CGFloat, glyph: CGFloat, radius: CGFloat
        static let centered = Metrics(fieldHeight: 60, rowHeight: 44, fontSize: 20, glyph: 16, radius: 14)
        static let anchored = Metrics(fieldHeight: 46, rowHeight: 40, fontSize: 15, glyph: 13, radius: 12)
    }

    private var metrics: Metrics { anchor == nil ? .centered : .anchored }

    var isOpen: Bool { superview != nil }
    /// What it opens goes beside the tab in front, as a split (⌥⌘\), rather than into a tab of its own.
    var opensBeside = false

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
        opensBeside = false
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
        // A long address shows its end (the path, the query), all of it still selected to type over.
        (field.currentEditor() as? NSTextView)?.scrollRangeToVisible(NSRange(location: (field.stringValue as NSString).length, length: 0))
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
        endAnswer()
        removeFromSuperview()
        controller?.commandBarDidHide()
    }

    override func mouseDown(with event: NSEvent) {
        if !cardContains(event.locationInWindow) { hide() }
    }

    /// Whether a point in the window is on the bar's card (its field and suggestions), not on what's around it.
    func cardContains(_ windowPoint: NSPoint) -> Bool {
        isOpen && shadowHost.frame.contains(convert(windowPoint, from: nil))
    }

    /// Outside the card the sidebar stays reachable: its presses go straight to it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !shadowHost.frame.contains(local), controller?.sidebarTakesPress(at: convert(local, to: nil)) == true { return nil }
        return super.hitTest(point)
    }

    /// The card's width, which doesn't depend on what it shows.
    private var cardWidth: CGFloat {
        if let anchor {
            let x = max(4, anchor.minX - 4)
            return min(max(anchor.width + 8, 400), bounds.width - x - 8)
        }
        if let over { return over.width }
        return min(660, bounds.width - 64)
    }

    override func layout() {
        super.layout()
        let m = metrics
        let listHeight = answer.map { $0.height(forWidth: cardWidth) } ?? (rows.isEmpty ? 0 : CGFloat(rows.count) * m.rowHeight + 12)
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
        separator.isHidden = rows.isEmpty && answer == nil
        answer?.frame = NSRect(x: 0, y: 0, width: width, height: listHeight)
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
            let search = URLInput.isSearch(text)
            list.append(search ? .search(text) : .open(URLInput.resolve(text)))
            if search, controller?.asksAI == true { list.append(.ask(text)) }
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
        case .search, .ask: return nil
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
        if case let .ask(question) = suggestion { return ask(question) }
        let beside = opensBeside, editing = self.editing
        hide()
        let open = { (input: String) in
            if editing { controller.navigate(input) } else if beside { controller.openBeside(input) } else { controller.openInNewTab(input) }
        }
        switch suggestion {
        case let .open(url): open(url)
        case let .search(query): open(query)
        case .ask: break
        case let .tab(item, _): controller.select(item, cause: "command-bar")
        case let .history(url, _): open(url)
        }
    }

    #if DRIFT_DEV
    func debugType(_ text: String) {
        field.stringValue = text
        field.currentEditor()?.selectedRange = NSRange(location: text.count, length: 0)
        refresh()
    }
    #endif

    // MARK: asking the AI

    private func ask(_ question: String) {
        answering?.cancel()
        let view: ChatView
        if let answer {
            view = answer
        } else {
            rows.forEach { $0.removeFromSuperview() }
            rows = []
            suggestions = []
            selected = -1
            view = ChatView(model: AIService.shared.settings.resolvedModel)
            view.onCopy = { [weak view] in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(view?.lastAnswer ?? "", forType: .string)
            }
            view.onSearch = { [weak self, weak view] in
                guard let self, let controller, let question = view?.lastQuestion else { return }
                let beside = opensBeside, editing = self.editing
                hide()
                if editing { controller.navigate(question) } else if beside { controller.openBeside(question) } else { controller.openInNewTab(question) }
            }
            view.onSettings = { [weak self] in
                self?.hide()
                SettingsWindowController.shared.show(section: .ai)
            }
            view.onResize = { [weak self] in self?.needsLayout = true }
            card.addSubview(view)
            answer = view
            glyph.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: metrics.glyph, weight: .semibold))
        }
        view.begin(question)
        // What was asked and answered before this question, for the follow-up's context.
        let history = view.turns
        field.stringValue = ""
        field.placeholderAttributedString = NSAttributedString(string: L("ai.ask.followUp"), attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.systemFont(ofSize: metrics.fontSize),
        ])
        needsLayout = true
        Trace.log("ask AI: \(question.count) characters, \(history.count) before")
        answering = Task { @MainActor [weak view] in
            do {
                for try await piece in AIService.shared.stream(AskAI.request(question, after: history)) { view?.append(piece) }
                view?.finish()
            } catch is CancellationError {
            } catch {
                let failure = error as? AIError ?? .failed(error.localizedDescription)
                Trace.log("ask AI failed: \(failure)")
                view?.fail(failure)
            }
        }
    }

    private func endAnswer() {
        answering?.cancel()
        answering = nil
        answer?.removeFromSuperview()
        answer = nil
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        // In a conversation the field takes the next question.
        if answer == nil { refresh() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            if !rows.isEmpty { select(min(selected + 1, rows.count - 1)) }
        case #selector(NSResponder.moveUp(_:)):
            if !rows.isEmpty { select(max(selected - 1, 0)) }
        case #selector(NSResponder.insertTab(_:)):
            // Tab asks the AI, when it's there to ask.
            guard answer == nil, let index = suggestions.firstIndex(where: { if case .ask = $0 { true } else { false } }) else { return false }
            run(index)
        case #selector(NSResponder.insertNewline(_:)):
            if let answer {
                let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty, !answer.isWriting { ask(text) }
                return true
            }
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
        case let .ask(question):
            icon.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
            title.stringValue = question
            detail.stringValue = L("ai.ask.detail")
            hint.stringValue = L("ai.ask.hint")
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


/// The conversation with the AI in the command bar: a quiet header naming the model, then each question and its answer,
/// the newest written in as it comes. Under it, small buttons: copy the answer, search the question instead, and, when
/// the AI can't answer for a reason Settings fixes, the way there. A failure says why in plain words.
private final class ChatView: NSView {
    var onCopy: (() -> Void)?
    var onSearch: (() -> Void)?
    var onSettings: (() -> Void)?
    /// The text grew: the bar sizes to it.
    var onResize: (() -> Void)?

    /// Questions answered, oldest first, for the follow-ups' context.
    private(set) var turns: [(question: String, answer: String)] = []
    private(set) var lastQuestion: String?
    private var writing = ""
    private var failure: AIError?
    private(set) var isWriting = false
    var lastAnswer: String { isWriting || !writing.isEmpty ? writing : turns.last?.answer ?? "" }

    private let header = NSTextField(labelWithString: "")
    private let headerIcon = NSImageView()
    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private let hint = NSTextField(labelWithString: L("ai.ask.keys"))
    private let copyButton = ChatButton(symbol: "doc.on.doc", tip: L("ai.ask.copy"))
    private let searchButton = ChatButton(symbol: "magnifyingglass", tip: L("command.searchWith", URLInput.engine.name))
    private let settingsButton = ChatButton(symbol: "gearshape", tip: L("ai.settings.open"))
    private static let headerHeight: CGFloat = 30
    private static let footer: CGFloat = 34
    private static let maxText: CGFloat = 380

    init(model: String) {
        super.init(frame: .zero)
        headerIcon.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        headerIcon.contentTintColor = .systemPurple
        header.stringValue = model.isEmpty ? L("ai.name") : "\(L("ai.name")) · \(model)"
        header.font = .systemFont(ofSize: 11, weight: .medium)
        header.textColor = .tertiaryLabelColor
        header.lineBreakMode = .byTruncatingTail
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 14, height: 4)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .right
        [headerIcon, header, scroll, hint, copyButton, searchButton, settingsButton].forEach(addSubview)
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        searchButton.target = self
        searchButton.action = #selector(searchTapped)
        settingsButton.target = self
        settingsButton.action = #selector(settingsTapped)
        copyButton.isHidden = true
        settingsButton.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A new question: the last answer joins the conversation, and the new one is waited for.
    func begin(_ question: String) {
        if let lastQuestion, !writing.isEmpty, failure == nil { turns.append((lastQuestion, writing)) }
        lastQuestion = question
        writing = ""
        failure = nil
        isWriting = true
        settingsButton.isHidden = true
        copyButton.isHidden = true
        redraw()
    }

    func append(_ piece: String) {
        writing += piece
        redraw()
    }

    func finish() {
        isWriting = false
        if writing.isEmpty { return fail(.unreadable) }
        copyButton.isHidden = false
        redraw()
    }

    func fail(_ error: AIError) {
        isWriting = false
        failure = error
        settingsButton.isHidden = !error.needsSettings
        copyButton.isHidden = writing.isEmpty
        redraw()
    }

    private func redraw() {
        let text = NSMutableAttributedString()
        let question = NSMutableParagraphStyle()
        question.paragraphSpacingBefore = 4
        question.paragraphSpacing = 4
        let all = turns.map { ($0.question, Optional($0.answer)) } + (lastQuestion.map { [($0, Optional<String>.none)] } ?? [])
        for (index, turn) in all.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "\n\n")) }
            text.append(NSAttributedString(string: turn.0 + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: question,
            ]))
            if let answer = turn.1 {
                text.append(Self.render(answer))
                continue
            }
            // The question being answered: what's written so far, or a word that it's coming, and what went wrong.
            if !writing.isEmpty {
                text.append(Self.render(writing + (isWriting ? " ▍" : "")))
            } else if failure == nil {
                text.append(NSAttributedString(string: L("ai.ask.thinking"), attributes: [.font: NSFont.systemFont(ofSize: 14),
                                                                                         .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            if let failure {
                text.append(NSAttributedString(string: (writing.isEmpty ? "" : "\n") + failure.message,
                                               attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.systemOrange]))
            }
        }
        textView.textStorage?.setAttributedString(text)
        onResize?()
        needsLayout = true
        textView.scrollToEndOfDocument(nil)
    }

    /// As tall as the conversation (up to a point, then it scrolls), with the header and the buttons.
    func height(forWidth width: CGFloat) -> CGFloat {
        var body: CGFloat = 40
        if let manager = textView.layoutManager, let container = textView.textContainer {
            container.containerSize = NSSize(width: max(0, width - 28), height: .greatestFiniteMagnitude)
            manager.ensureLayout(for: container)
            body = min(Self.maxText, max(body, ceil(manager.usedRect(for: container).height) + 12))
        }
        return Self.headerHeight + body + Self.footer
    }

    override func layout() {
        super.layout()
        // Not flipped: the buttons at the bottom, the header at the top, the conversation between.
        let width = bounds.width
        headerIcon.frame = NSRect(x: 16, y: bounds.height - 22, width: 14, height: 14)
        header.frame = NSRect(x: 36, y: bounds.height - 23, width: width - 52, height: 15)
        scroll.frame = NSRect(x: 0, y: Self.footer, width: width, height: max(0, bounds.height - Self.headerHeight - Self.footer))
        textView.frame.size.width = width
        var x: CGFloat = 12
        for button in [copyButton, searchButton, settingsButton] where !button.isHidden {
            button.frame = NSRect(x: x, y: 6, width: 26, height: 24)
            x += 28
        }
        hint.frame = NSRect(x: x + 8, y: 11, width: max(0, width - x - 24), height: 14)
    }

    @objc private func copyTapped() { onCopy?() }
    @objc private func searchTapped() { onSearch?() }
    @objc private func settingsTapped() { onSettings?() }

    /// An answer's Markdown, the inline kind (bold, italics, code, links); lists and line breaks stay as written.
    static func render(_ markdown: String) -> NSAttributedString {
        let base = NSFont.systemFont(ofSize: 14)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? NSAttributedString(markdown: markdown, options: options, baseURL: nil)) ?? NSAttributedString(string: markdown)
        let result = NSMutableAttributedString(attributedString: parsed)
        let whole = NSRange(location: 0, length: result.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        result.addAttributes([.font: base, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph], range: whole)
        result.enumerateAttribute(.inlinePresentationIntent, in: whole) { value, range, _ in
            guard let raw = (value as? NSNumber)?.uintValue ?? (value as? InlinePresentationIntent)?.rawValue else { return }
            let intent = InlinePresentationIntent(rawValue: raw)
            var font = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) : base
            if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            result.addAttribute(.font, value: font, range: range)
        }
        return result
    }
}

/// A small borderless icon button under the AI's answer, lit while hovered.
private final class ChatButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }

    init(symbol: String, tip: String) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        isBordered = false
        imagePosition = .imageOnly
        contentTintColor = .secondaryLabelColor
        toolTip = tip
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            Theme.hairline.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}
