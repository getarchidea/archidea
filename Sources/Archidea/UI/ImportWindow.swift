import AppKit
import ArchideaCore

/// Import from another browser: pick the browser (and profile), pick what to bring, watch it come over.
final class ImportWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = ImportWindowController()

    private var sources: [BrowserSource] = []
    private let list = NSTableView()
    private let detail = NSStackView()
    private var source: BrowserSource?
    private var profile: BrowserProfile?
    private var chosen = Set<ImportPart>()
    private var safariExport: URL?
    private var running = false

    private var browser: BrowserWindowController? { (NSApp.delegate as? AppDelegate)?.windowController }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = L("import.title")
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(selecting wanted: BrowserSource? = nil) {
        guard !running else { return window?.makeKeyAndOrderFront(nil) ?? () }
        sources = ImportService.shared.sources()
        list.reloadData()
        let index = sources.firstIndex(where: { $0.id == wanted?.id }) ?? sources.indices.first
        if let index { list.selectRowIndexes([index], byExtendingSelection: false) }
        select(index.map { sources[$0] })
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

        list.addTableColumn(NSTableColumn(identifier: .init("browser")))
        list.headerView = nil
        list.style = .sourceList
        list.rowHeight = 34
        list.backgroundColor = .clear
        list.dataSource = self
        list.delegate = self
        let scroll = ThinScrollView()
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        side.addSubview(scroll)

        let heading = NSTextField(labelWithString: L("import.title"))
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(heading)

        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 14
        detail.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(detail)

        NSLayoutConstraint.activate([
            side.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            side.topAnchor.constraint(equalTo: content.topAnchor),
            side.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            side.widthAnchor.constraint(equalToConstant: 230),
            scroll.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: side.topAnchor, constant: 48),
            scroll.bottomAnchor.constraint(equalTo: side.bottomAnchor, constant: -8),
            heading.leadingAnchor.constraint(equalTo: side.trailingAnchor, constant: 28),
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            detail.leadingAnchor.constraint(equalTo: side.trailingAnchor, constant: 28),
            detail.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            detail.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 18),
        ])
    }

    // MARK: choosing

    private func select(_ next: BrowserSource?) {
        source = next
        profile = next?.profiles.first(where: \.isDefault) ?? next?.profiles.first
        safariExport = nil
        chosen = Set(parts)
        render()
    }

    private var parts: [ImportPart] {
        guard let source else { return [] }
        return ImportService.shared.parts(for: source, profile: profile)
    }

    private var safariNeedsExport: Bool {
        source?.family == .safari && !SafariDirect.hasAccess() && safariExport == nil
    }

    private func render() {
        detail.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let source else {
            detail.addArrangedSubview(label(L("import.none"), secondary: true))
            return
        }
        if source.profiles.count > 1 {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: source.profiles.map(\.name))
            if let profile, let index = source.profiles.firstIndex(where: { $0.id == profile.id }) { popup.selectItem(at: index) }
            popup.target = self
            popup.action = #selector(profileChanged(_:))
            detail.addArrangedSubview(row(label(L("import.profile")), popup))
        }
        if safariNeedsExport {
            detail.addArrangedSubview(label(L("import.safari.access"), secondary: true, wrap: true))
            let buttons = NSStackView(views: [
                button(L("import.safari.openAccess"), #selector(openFullDiskAccess)),
                button(L("import.safari.chooseExport"), #selector(chooseSafariExport)),
            ])
            buttons.spacing = 8
            detail.addArrangedSubview(buttons)
            return
        }
        if parts.isEmpty {
            detail.addArrangedSubview(label(L("import.nothing"), secondary: true))
            return
        }
        for part in parts {
            let box = NSButton(checkboxWithTitle: part.title, target: self, action: #selector(partToggled(_:)))
            box.identifier = NSUserInterfaceItemIdentifier(part.rawValue)
            box.state = chosen.contains(part) ? .on : .off
            detail.addArrangedSubview(box)
        }
        if source.needsKeychain, !chosen.filter(\.needsKeychain).isEmpty {
            detail.addArrangedSubview(label(L("import.keychain", source.name), secondary: true, wrap: true))
        }
        let quits = ImportService.shared.runningApp(of: source) != nil && !chosen.filter(\.needsKeychain).isEmpty
        if quits { detail.addArrangedSubview(label(L("import.runningNote", source.name), secondary: true, wrap: true)) }
        let start = button(quits ? L("import.quitAndImport", source.name) : L("import.start"), #selector(start))
        start.keyEquivalent = "\r"
        start.isEnabled = !chosen.isEmpty && !running
        detail.addArrangedSubview(start)
        detail.addArrangedSubview(label(L("import.csv.hint"), secondary: true, wrap: true))
        detail.addArrangedSubview(button(L("import.csv"), #selector(importCSV)))
    }

    /// Apple Passwords (File › Export All Passwords) and most password managers export a CSV.
    @objc private func importCSV() {
        guard let browser, !running else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = L("import.csv.hint")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        running = true
        detail.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let status = label(L("import.progress.passwords"))
        detail.addArrangedSubview(status)
        ImportService.shared.importPasswords(csv: url, into: browser, progress: { status.stringValue = $0 }) { [weak self] result in
            self?.finished(result)
        }
    }

    @objc private func profileChanged(_ sender: NSPopUpButton) {
        guard let source, sender.indexOfSelectedItem >= 0 else { return }
        profile = source.profiles[sender.indexOfSelectedItem]
        chosen = Set(parts)
        render()
    }

    @objc private func partToggled(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let part = ImportPart(rawValue: raw) else { return }
        if sender.state == .on { chosen.insert(part) } else { chosen.remove(part) }
        render()
    }

    @objc private func openFullDiskAccess() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    @objc private func chooseSafariExport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip, .folder]
        panel.canChooseDirectories = true
        panel.message = L("import.safari.chooseExport")
        guard let window, panel.runModal() == .OK, let url = panel.url else { return }
        _ = window
        safariExport = url
        render()
    }

    @objc private func start() {
        guard let source, let browser, !running else { return }
        running = true
        detail.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let status = label(L("import.progress.reading", source.name))
        detail.addArrangedSubview(row(spinner, status))
        if let app = ImportService.shared.runningApp(of: source), !chosen.filter(\.needsKeychain).isEmpty {
            status.stringValue = L("import.progress.quitting", source.name)
            ImportService.shared.quit(app) { [weak self] quit in
                guard let self else { return }
                running = false
                if quit { start() } else { finished(.failure(ImportQuitError(name: source.name))) }
            }
            return
        }
        ImportService.shared.run(source: source, profile: profile, parts: chosen, safariExport: safariExport, into: browser,
                                 progress: { status.stringValue = $0 }) { [weak self] result in
            self?.finished(result)
        }
    }

    private func finished(_ result: Result<ImportSummary, Error>) {
        running = false
        detail.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch result {
        case let .success(summary):
            detail.addArrangedSubview(label(summary.lines.isEmpty ? L("import.done.empty") : L("import.done"), secondary: false))
            for line in summary.lines { detail.addArrangedSubview(label("•  " + line, secondary: true)) }
            for warning in summary.warnings.prefix(5) { detail.addArrangedSubview(label("⚠︎  " + warning, secondary: true, wrap: true)) }
        case let .failure(error):
            detail.addArrangedSubview(label(L("import.failed"), secondary: false))
            detail.addArrangedSubview(label(String(describing: error), secondary: true, wrap: true))
        }
        let buttons = NSStackView(views: [button(L("import.another"), #selector(again)), button(L("import.close"), #selector(closeWindow))])
        buttons.spacing = 8
        detail.addArrangedSubview(buttons)
    }

    @objc private func again() { render() }
    @objc private func closeWindow() { window?.close() }

    // MARK: pieces

    private func label(_ text: String, secondary: Bool = false, wrap: Bool = false) -> NSTextField {
        let field = wrap ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 13)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        if wrap { field.preferredMaxLayoutWidth = 420 }
        return field
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func row(_ views: NSView...) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.spacing = 10
        stack.alignment = .centerY
        return stack
    }

    // MARK: list

    func numberOfRows(in tableView: NSTableView) -> Int { sources.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let source = sources[row]
        let cell = NSTableCellView()
        let icon = NSImageView()
        icon.image = source.iconPath.flatMap { NSImage(contentsOfFile: $0) }
            ?? source.appPath.map { NSWorkspace.shared.icon(forFile: $0) }
            ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        let name = NSTextField(labelWithString: source.name)
        name.font = .systemFont(ofSize: 13)
        for view in [icon, name] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !running else { return }
        let row = list.selectedRow
        select(row >= 0 ? sources[row] : nil)
    }
}
