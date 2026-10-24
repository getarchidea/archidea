import AppKit

/// Drift's own settings: a plain AppKit window, sections on the left, grouped cards on the right.
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    enum Section: String, CaseIterable {
        case general, tabs, spaces, privacy, extensions, shortcuts, advanced

        var title: String { L("settings.section.\(rawValue)") }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .tabs: return "square.on.square"
            case .spaces: return "square.stack.3d.up"
            case .privacy: return "hand.raised"
            case .extensions: return "puzzlepiece.extension"
            case .shortcuts: return "keyboard"
            case .advanced: return "slider.horizontal.3"
            }
        }
    }

    static let shared = SettingsWindowController()

    private let list = NSTableView()
    private let heading = NSTextField(labelWithString: "")
    private let scroll = ThinScrollView()
    private var section = Section.general

    private var app: AppDelegate? { NSApp.delegate as? AppDelegate }
    private var browser: BrowserWindowController? { app?.windowController }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = L("settings.title")
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("DriftSettings")
        super.init(window: window)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(section: Section = .general) {
        select(section)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        guard let content = window?.contentView else { return }
        let side = NSVisualEffectView()
        side.material = .sidebar
        side.blendingMode = .behindWindow
        side.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(side)

        let column = NSTableColumn(identifier: .init("section"))
        list.addTableColumn(column)
        list.headerView = nil
        list.style = .sourceList
        list.rowHeight = 28
        list.backgroundColor = .clear
        list.dataSource = self
        list.delegate = self
        let listScroll = ThinScrollView()
        listScroll.documentView = list
        listScroll.drawsBackground = false
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        side.addSubview(listScroll)

        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(heading)

        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)

        NSLayoutConstraint.activate([
            side.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            side.topAnchor.constraint(equalTo: content.topAnchor),
            side.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            side.widthAnchor.constraint(equalToConstant: 224),
            listScroll.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: 8),
            listScroll.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -8),
            listScroll.topAnchor.constraint(equalTo: side.topAnchor, constant: 48),
            listScroll.bottomAnchor.constraint(equalTo: side.bottomAnchor, constant: -8),
            heading.leadingAnchor.constraint(equalTo: side.trailingAnchor, constant: 24),
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: side.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 48),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func select(_ next: Section) {
        section = next
        if let row = Section.allCases.firstIndex(of: next), list.selectedRow != row {
            list.selectRowIndexes([row], byExtendingSelection: false)
        }
        render()
    }

    /// Rebuilds the current section from the live state; settings apply as soon as they change.
    func render() {
        heading.stringValue = section.title
        let stack = FlippedStack()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 24, bottom: 24, right: 24)
        for view in views(for: section) { stack.addArrangedSubview(view) }
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        for case let card as SettingsCard in stack.arrangedSubviews {
            card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }
    }

    // MARK: sections

    private func views(for section: Section) -> [NSView] {
        switch section {
        case .general: return general()
        case .tabs: return tabs()
        case .spaces: return spaces()
        case .privacy: return privacy()
        case .extensions: return extensions()
        case .shortcuts: return shortcuts()
        case .advanced: return advanced()
        }
    }

    private func general() -> [NSView] {
        let language = popup(AppLanguage.allCases.map { L("settings.language.\($0.rawValue)") },
                             selected: AppLanguage.allCases.firstIndex(of: AppLanguage.setting) ?? 0) { [weak self] index in
            AppLanguage.setting = AppLanguage.allCases[index]
            self?.render()
        }
        let restartNeeded = AppLanguage.setting.resolved != L10n.code
        var languageRows = [SettingsRow(title: L("settings.language"), detail: L("settings.language.detail"), control: language)]
        if restartNeeded {
            languageRows.append(SettingsRow(title: L("settings.language.restart"), detail: nil,
                                            control: button(L("settings.restart")) { Relaunch.now() }))
        }

        let isDefault = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)?.standardizedFileURL
            == Bundle.main.bundleURL.standardizedFileURL
        let makeDefault = button(isDefault ? L("settings.default.is") : L("settings.default.make")) { [weak self] in
            for scheme in ["http", "https"] {
                NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme) { _ in
                    DispatchQueue.main.async { self?.render() }
                }
            }
        }
        makeDefault.isEnabled = !isDefault

        let links = popup([L("settings.links.mini"), L("settings.links.browser")], selected: settings.linksInMiniWindow ? 0 : 1) { [weak self] index in
            self?.update { $0.linksInMiniWindow = index == 0 }
        }

        let engines = SearchEngine.allCases
        let engine = popup(engines.map(\.name), selected: engines.firstIndex(of: settings.searchEngine) ?? 0) { [weak self] index in
            self?.update { $0.searchEngine = engines[index] }
        }
        return [
            SettingsCard(rows: languageRows),
            SettingsCard(rows: [SettingsRow(title: L("settings.icon"), detail: nil, control: IconChoiceView(tileSize: 36))]),
            SettingsCard(rows: [
                SettingsRow(title: L("settings.default"), detail: L("settings.default.detail"), control: makeDefault),
                SettingsRow(title: L("settings.links"), detail: L("settings.links.detail"), control: links),
                SettingsRow(title: L("settings.search"), detail: nil, control: engine),
            ]),
        ]
    }

    private func tabs() -> [NSView] {
        let archive = choice([12, 24, 168, 0], current: settings.archiveHours, label: { hours in
            hours == 0 ? L("settings.never") : hours < 48 ? L("settings.hours", hours) : L("settings.days", hours / 24)
        }) { [weak self] value in self?.update { $0.archiveHours = value } }
        let unload = choice([15, 30, 60, 0], current: settings.unloadMinutes, label: { minutes in
            minutes == 0 ? L("settings.never") : minutes < 60 ? L("settings.minutes", minutes) : L("settings.hours", minutes / 60)
        }) { [weak self] value in self?.update { $0.unloadMinutes = value } }
        let keep = choice([0, 5, 15, 60], current: settings.clearKeepsMinutes, label: { minutes in
            minutes == 0 ? L("settings.keep.none") : minutes < 60 ? L("settings.minutes", minutes) : L("settings.hours", minutes / 60)
        }) { [weak self] value in self?.update { $0.clearKeepsMinutes = value } }
        return [SettingsCard(rows: [
            SettingsRow(title: L("settings.archive"), detail: L("settings.archive.detail"), control: archive),
            SettingsRow(title: L("settings.unload"), detail: L("settings.unload.detail"), control: unload),
            SettingsRow(title: L("settings.clear"), detail: L("settings.clear.detail"), control: keep),
        ])]
    }

    private func spaces() -> [NSView] {
        guard let browser else { return [] }
        let rows = browser.state.spaces.map { space -> SettingsRow in
            weak var anchor: NSButton?
            let theme = button(L("settings.spaces.theme")) {
                if let anchor { browser.editTheme(space, from: anchor) }
            }
            anchor = theme
            let rename = button(L("settings.spaces.rename")) { [weak self] in
                browser.rename(space)
                self?.render()
            }
            let delete = button(L("settings.spaces.delete")) { [weak self] in
                browser.delete(space)
                self?.render()
            }
            delete.isEnabled = browser.state.spaces.count > 1
            let actions = NSStackView(views: [theme, rename, delete])
            actions.spacing = 6
            let row = SettingsRow(title: space.name, detail: nil, control: actions)
            row.setIcon(space.symbol, color: NSColor(hex: space.colorHex))
            return row
        }
        let add = button(L("settings.spaces.new")) { [weak self] in
            browser.newSpace()
            self?.render()
        }
        return [SettingsCard(rows: rows), add]
    }

    private func privacy() -> [NSView] {
        let blocker = ClosureSwitch(on: settings.adBlock) { [weak self] on in self?.update { $0.adBlock = on } }
        var rows = [
            SettingsRow(title: L("settings.adBlock"), detail: L("settings.adBlock.detail"), control: blocker),
            SettingsRow(title: L("settings.passwords"), detail: L("settings.passwords.detail"),
                        control: button(L("settings.open")) { [weak self] in self?.openPage("chrome://password-manager/passwords") }),
            SettingsRow(title: L("settings.import"), detail: L("settings.import.detail"),
                        control: button(L("settings.open")) { [weak self] in self?.openPage("chrome://password-manager/settings") }),
            SettingsRow(title: L("settings.clearData"), detail: nil,
                        control: button(L("settings.open")) { [weak self] in self?.openPage("chrome://settings/clearBrowserData") }),
            SettingsRow(title: L("settings.sitePermissions"), detail: nil,
                        control: button(L("settings.open")) { [weak self] in self?.openPage("chrome://settings/content") }),
        ]
        if ProcessInfo.processInfo.environment["DRIFT_REAL_KEYCHAIN"] == nil {
            rows.append(SettingsRow(title: L("settings.keychain"), detail: L("settings.keychain.detail"), control: NSView()))
        }
        let installed = Set((browser?.profile.extensions ?? []).compactMap { $0["id"] as? String })
        var managers = [SettingsRow(title: "Apple Passwords", detail: L("settings.managers.apple"),
                                    control: button(L("import.csv")) { ImportWindowController.shared.show() })]
        managers += PasswordManagers.all.filter(PasswordManagers.isAvailable).map { manager -> SettingsRow in
            let connected = installed.contains(manager.extensionID)
            let control: NSView = connected ? KeysLabel(L("settings.managers.connected"))
                : button(L("settings.managers.install")) { [weak self] in
                    self?.openPage("https://chromewebstore.google.com/detail/\(manager.extensionID)")
                }
            return SettingsRow(title: manager.name, detail: connected ? nil : L("settings.managers.detail"), control: control)
        }
        var cards: [NSView] = [SettingsCard(rows: rows)]
        if !managers.isEmpty {
            let title = NSTextField(labelWithString: L("settings.managers"))
            title.font = .systemFont(ofSize: 12, weight: .semibold)
            title.textColor = .secondaryLabelColor
            cards += [title, SettingsCard(rows: managers)]
        }
        return cards
    }

    private func extensions() -> [NSView] {
        let installed = (browser?.profile.extensions ?? []).sorted {
            ($0["name"] as? String ?? "").localizedCaseInsensitiveCompare($1["name"] as? String ?? "") == .orderedAscending
        }
        var views: [NSView] = []
        if installed.isEmpty {
            views.append(SettingsCard(rows: [SettingsRow(title: L("extensions.none"), detail: nil, control: NSView())]))
        } else {
            views.append(SettingsCard(rows: installed.map { ext in
                let row = SettingsRow(title: ext["name"] as? String ?? "", detail: ext["version"] as? String, control: NSView())
                row.setIcon("puzzlepiece.extension", color: .secondaryLabelColor)
                return row
            }))
        }
        let buttons = NSStackView(views: [
            button(L("menu.webStore")) { [weak self] in self?.openPage("https://chromewebstore.google.com/category/extensions") },
            button(L("extensions.manage")) { [weak self] in self?.openPage("chrome://extensions") },
        ])
        buttons.spacing = 8
        views.append(buttons)
        return views
    }

    private func shortcuts() -> [NSView] {
        let list: [(String, String)] = [
            ("menu.newTab", "⌘T"), ("menu.openLocation", "⌘L"), ("menu.closeTab", "⌘W"), ("menu.reopenClosedTab", "⇧⌘T"),
            ("menu.togglePin", "⌘D"), ("menu.toggleSidebar", "⌘S"), ("menu.find", "⌘F"), ("menu.copyURL", "⇧⌘C"),
            ("menu.nextTab", "⌃⇥"), ("menu.previousTab", "⌃⇧⇥"), ("menu.nextSpace", "⌥⌘→"), ("menu.previousSpace", "⌥⌘←"),
            ("menu.newPrivateWindow", "⇧⌘N"), ("menu.newSpace", "⌃⌘N"), ("menu.newFolder", "⌥⌘N"), ("menu.devTools", "⌥⌘I"), ("menu.settings", "⌘,"),
        ]
        return [SettingsCard(rows: list.map { key, keys in
            SettingsRow(title: L(key), detail: nil, control: KeysLabel(keys))
        })]
    }

    private func advanced() -> [NSView] {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let chromium = ArdiaCoreEngine.shared?.chromiumVersion ?? "-"
        let updater = Updater.shared
        let updates = SettingsCard(rows: [
            SettingsRow(title: L("settings.updates"), detail: updater.isEnabled ? L("update.version", updater.currentVersion) : L("update.notConfigured"),
                        control: button(L("settings.updates.check")) { (NSApp.delegate as? AppDelegate)?.checkForUpdates(nil) }),
            SettingsRow(title: L("settings.updates.auto"), detail: nil,
                        control: ClosureSwitch(on: updater.installsAutomatically) { updater.installsAutomatically = $0 }),
        ])
        return [
            updates,
            SettingsCard(rows: [
                SettingsRow(title: L("settings.welcome"), detail: nil,
                            control: button(L("settings.open")) { OnboardingWindowController.shared.show() }),
                SettingsRow(title: L("settings.import"), detail: L("settings.importBrowsers.detail"),
                            control: button(L("settings.open")) { ImportWindowController.shared.show() }),
                SettingsRow(title: L("settings.chromeSettings"), detail: L("settings.chromeSettings.detail"),
                            control: button(L("settings.open")) { [weak self] in self?.openPage("chrome://settings") }),
                SettingsRow(title: L("settings.dataFolder"), detail: Paths.root.path,
                            control: button(L("settings.showInFinder")) { NSWorkspace.shared.activateFileViewerSelecting([Paths.root]) }),
            ]),
            SettingsCard(rows: [
                SettingsRow(title: L("app.name"), detail: nil, control: KeysLabel(version)),
                SettingsRow(title: L("settings.engine"), detail: nil, control: KeysLabel("Chromium \(chromium)")),
            ]),
        ]
    }

    // MARK: helpers

    private var settings: BrowserSettings { browser?.settings ?? BrowserSettings() }

    private func update(_ change: (inout BrowserSettings) -> Void) {
        browser?.updateSettings(change)
    }

    private func openPage(_ url: String) {
        browser?.openInNewTab(url)
        browser?.showWindow()
    }

    private func popup(_ titles: [String], selected: Int, onChange: @escaping (Int) -> Void) -> NSPopUpButton {
        let popup = ClosurePopUp(titles: titles, onChange: onChange)
        popup.selectItem(at: selected)
        return popup
    }

    private func choice(_ values: [Int], current: Int, label: (Int) -> String, onChange: @escaping (Int) -> Void) -> NSPopUpButton {
        var options = values
        if !options.contains(current) { options.append(current) }
        return popup(options.map(label), selected: options.firstIndex(of: current) ?? 0) { onChange(options[$0]) }
    }

    private func button(_ title: String, action: @escaping () -> Void) -> NSButton {
        ClosureButton(title: title, action: action)
    }

    // MARK: list

    func numberOfRows(in tableView: NSTableView) -> Int { Section.allCases.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let section = Section.allCases[row]
        let cell = NSTableCellView()
        let icon = NSImageView(image: NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil)!)
        let label = NSTextField(labelWithString: section.title)
        label.font = .systemFont(ofSize: 13)
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)
        cell.addSubview(label)
        cell.imageView = icon
        cell.textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = list.selectedRow
        guard row >= 0, Section.allCases[row] != section else { return }
        section = Section.allCases[row]
        render()
    }
}

// MARK: - building blocks

private final class FlippedStack: NSStackView {
    override var isFlipped: Bool { true }
}

/// A rounded group of rows with hairlines between them.
final class SettingsCard: NSView {
    init(rows: [NSView]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, row) in rows.enumerated() {
            if index > 0 { stack.addArrangedSubview(Hairline()) }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.settingsCard.cgColor
        layer?.borderColor = Theme.hairline.cgColor
        layer?.borderWidth = 1
    }
}

private final class Hairline: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 1) }
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() { layer?.backgroundColor = Theme.hairline.cgColor }
}

/// Title (and an optional detail line) on the left, a control on the right.
final class SettingsRow: NSView {
    let control: NSView
    private let icon = NSImageView()
    private let titleLabel: NSTextField
    private var leadingToIcon: NSLayoutConstraint!
    private var leadingToEdge: NSLayoutConstraint!

    init(title: String, detail: String?, control: NSView) {
        self.control = control
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        titleLabel.font = .systemFont(ofSize: 13)
        let texts = NSStackView(views: [titleLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        if let detail, !detail.isEmpty {
            let detailLabel = NSTextField(wrappingLabelWithString: detail)
            detailLabel.font = .systemFont(ofSize: 11)
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.preferredMaxLayoutWidth = 320
            texts.addArrangedSubview(detailLabel)
        }
        icon.isHidden = true
        for view in [icon, texts, control] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        leadingToEdge = texts.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14)
        leadingToIcon = texts.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10)
        NSLayoutConstraint.activate([
            leadingToEdge,
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            texts.centerYAnchor.constraint(equalTo: centerYAnchor),
            texts.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
            texts.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -16),
            control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
            // A tall control (the icon grid) makes the row taller instead of spilling out of it.
            control.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
            control.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setIcon(_ symbol: String, color: NSColor) {
        icon.image = NSImage(systemSymbolName: "\(symbol).fill", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = color
        icon.isHidden = false
        leadingToEdge.isActive = false
        leadingToIcon.isActive = true
    }
}

private final class KeysLabel: NSTextField {
    init(_ text: String) {
        super.init(frame: .zero)
        stringValue = text
        isEditable = false
        isBordered = false
        drawsBackground = false
        font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        textColor = .secondaryLabelColor
    }

    required init?(coder: NSCoder) { fatalError() }
}

private final class ClosureButton: NSButton {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        controlSize = .regular
        target = self
        self.action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

private final class ClosureSwitch: NSSwitch {
    private let handler: (Bool) -> Void

    init(on: Bool, onChange: @escaping (Bool) -> Void) {
        handler = onChange
        super.init(frame: .zero)
        state = on ? .on : .off
        target = self
        action = #selector(changed)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() { handler(state == .on) }
}

private final class ClosurePopUp: NSPopUpButton {
    private let handler: (Int) -> Void

    init(titles: [String], onChange: @escaping (Int) -> Void) {
        handler = onChange
        super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: titles)
        target = self
        action = #selector(changed)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() { handler(indexOfSelectedItem) }
}

/// Starts a fresh copy of the app once this one has quit, for settings that apply at launch.
enum Relaunch {
    static func now() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The path goes in as an argument, not into the script, so no character in it can change what runs.
        task.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; open \"$2\"",
                          "relaunch", "\(ProcessInfo.processInfo.processIdentifier)", path]
        try? task.run()
        (NSApp.delegate as? AppDelegate)?.quit(nil)
    }
}
