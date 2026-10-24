import AppKit
import CoreImage
import QuartzCore
import ServiceManagement

/// The first launch: only this window, no browser behind it. Text on the left, a painting on the right that changes
/// with each step: welcome, bring everything over from another browser, pick a look, a few preferences, the keys
/// worth knowing — then the browser window comes up.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private static let doneKey = "OnboardingDone"

    /// Whether the first launch still owes the user this window. Test instances (DRIFT_DATA_DIR) skip it.
    static var isNeeded: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["DRIFT_DEMO"] == "onboarding" { return true }
        return !UserDefaults.standard.bool(forKey: doneKey) && env["DRIFT_DATA_DIR"] == nil
    }

    /// Runs once, when the user is through (or closes the window): the browser window comes up.
    var onFinish: (() -> Void)?

    private enum Step: Int, CaseIterable { case welcome, importing, look, preferences, ready }

    private static let size = NSSize(width: 960, height: 600)
    private static let column: CGFloat = 440

    private var step = Step.welcome
    private let art = ArtPanel()
    private let stage = NSView()
    private let progress = ProgressBar()
    private var page: NSView?

    private var sources: [BrowserSource] = []
    private var chosen: BrowserSource?
    private var importing = false
    private var imported: Result<ImportSummary, Error>?
    private var importParts: [ImportPart] = []
    private var importStatus = ""
    private var preferences = (adBlock: true, defaultBrowser: true, atLogin: false)

    private var browser: BrowserWindowController? { (NSApp.delegate as? AppDelegate)?.windowController }

    private init() {
        let window = OnboardingWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                                      styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.center()
        super.init(window: window)
        window.delegate = self
        window.onReturn = { [weak self] in self?.primaryAction?() }
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        step = .welcome
        sources = ImportService.shared.sources()
        chosen = sources.first { $0.id == "arc" } ?? sources.first
        imported = nil
        render(animated: false)
        window?.alphaValue = 1
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { complete() }

    private func build() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        art.frame = NSRect(x: 400, y: 0, width: Self.size.width - 400, height: Self.size.height)
        art.autoresizingMask = [.height, .minXMargin]
        content.addSubview(art)
        progress.frame = NSRect(x: 44, y: Self.size.height - 52, width: Self.column, height: 6)
        content.addSubview(progress)
        stage.frame = NSRect(x: 44, y: 36, width: Self.column, height: Self.size.height - 36 - 82)
        stage.wantsLayer = true
        content.addSubview(stage)
    }

    // MARK: rendering

    private var primaryAction: (() -> Void)?

    private func render(animated: Bool = true) {
        progress.set(fraction: CGFloat(step.rawValue + 1) / CGFloat(Step.allCases.count), animated: animated)
        art.show(scene(for: step), animated: animated)
        let next = view(for: step)
        next.frame = stage.bounds
        next.autoresizingMask = [.width, .height]
        next.wantsLayer = true
        stage.addSubview(next)
        let old = page
        page = next
        guard animated else { return old?.removeFromSuperview() ?? () }
        CATransaction.begin()
        CATransaction.setCompletionBlock { old?.removeFromSuperview() }
        old?.layer?.add(fade(from: 1, to: 0, duration: 0.16, delay: 0), forKey: "out")
        old?.layer?.opacity = 0
        for (index, part) in next.subviews.enumerated() {
            part.wantsLayer = true
            part.layer?.add(fade(from: 0, to: 1, duration: 0.5, delay: 0.08 + Double(index) * 0.05), forKey: "in")
        }
        CATransaction.commit()
    }

    private func fade(from: Float, to: Float, duration: CFTimeInterval, delay: CFTimeInterval) -> CAAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.beginTime = CACurrentMediaTime() + delay
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        return animation
    }

    private func scene(for step: Step) -> ArtPanel.Scene {
        switch step {
        case .welcome: return .bloom
        case .importing:
            if importing || imported != nil, let chosen { return .source(chosen) }
            return .orbit
        case .look: return .preview(browser?.space)
        case .preferences: return .dock
        case .ready: return .bloom
        }
    }

    private func view(for step: Step) -> NSView {
        switch step {
        case .welcome: return welcomeView()
        case .importing: return importing || imported != nil ? importProgressView() : importView()
        case .look: return lookView()
        case .preferences: return preferencesView()
        case .ready: return readyView()
        }
    }

    // MARK: steps

    private func welcomeView() -> NSView {
        let features = [("rectangle.split.2x1", L("onboarding.welcome.f1")),
                        ("square.and.arrow.down", L("onboarding.welcome.f2")),
                        ("hand.raised", L("onboarding.welcome.f3"))].map { FeatureRow(symbol: $0.0, text: $0.1) as NSView }
        let list = stack(features, spacing: 14)
        let divider = OnboardingHairline()
        return layout(title: L("onboarding.welcome.title"), text: L("onboarding.welcome.text"),
                      body: stack([divider, list], spacing: 26),
                      buttons: [button(L("onboarding.start"), .light) { [weak self] in self?.advance() }])
    }

    private func importView() -> NSView {
        var cards: [ChoiceCard] = []
        for source in sources.prefix(8) {
            let card = ChoiceCard(icon: icon(of: source), title: source.name, detail: nil, mark: .radio,
                                  selected: chosen?.id == source.id) { [weak self] in
                guard let self else { return }
                chosen = source
                cards.forEach { $0.selected = $0.title == source.name }
                note.stringValue = noteText()
            }
            cards.append(card)
        }
        let grid = rows(of: cards, columns: 2)
        note.stringValue = noteText()
        let body = stack(sources.isEmpty ? [label(L("import.none"), size: 13, alpha: 0.5)] : [grid, note], spacing: 14)
        let more = button(L("onboarding.import.more"), .link) { ImportWindowController.shared.show(selecting: nil) }
        return layout(title: L("onboarding.import.title"), text: L("onboarding.import.text"), body: stack([body, more], spacing: 10),
                      buttons: [button(L("onboarding.import.skip"), .dark) { [weak self] in self?.advance() },
                                button(L("onboarding.continue"), .light) { [weak self] in self?.runImport() }])
    }

    private lazy var note: NSTextField = {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = .systemFont(ofSize: 12)
        field.textColor = .white.withAlphaComponent(0.42)
        field.preferredMaxLayoutWidth = Self.column
        return field
    }()

    private func noteText() -> String {
        guard let chosen else { return "" }
        var lines: [String] = []
        if chosen.family == .safari, !SafariDirect.hasAccess() { lines.append(L("onboarding.import.safari")) }
        if ImportService.shared.runningApp(of: chosen) != nil { lines.append(L("import.runningNote", chosen.name)) }
        if chosen.needsKeychain { lines.append(L("onboarding.import.keychain", chosen.name)) }
        return lines.joined(separator: " ")
    }

    private func importProgressView() -> NSView {
        let order: [ImportPart] = [.spaces, .tabs, .bookmarks, .history, .passwords, .cookies]
        let parts = order.filter(importParts.contains)
        let current: Int = {
            if imported != nil { return parts.count }
            for (index, part) in parts.enumerated() where importStatus == L("import.progress.\(part.rawValue)") { return index }
            if ([.bookmarks, .history, .passwords, .cookies] as [ImportPart]).contains(where: { importStatus == L("import.progress.\($0.rawValue)") }) {
                return parts.firstIndex { ![.spaces, .tabs].contains($0) } ?? 0
            }
            return 0
        }()
        // Once done, each card says what came over for it; warnings (Google's sign-in, say) go in one note above.
        let summary: ImportSummary? = { if case let .success(summary)? = imported { return summary } else { return nil } }()
        let cards = parts.enumerated().map { index, part in
            ChoiceCard(icon: NSImage(systemSymbolName: Self.symbol(of: part), accessibilityDescription: nil), title: L("onboarding.part.\(part.rawValue)"),
                       detail: summary?.detail(for: part), mark: index < current ? .done : index == current ? .busy : .none, selected: false,
                       compact: true) {}
        }
        let status: NSView
        switch imported {
        case let .success(summary)?:
            let note = summary.lines.isEmpty && summary.warnings.isEmpty ? L("import.done.empty") : summary.warnings.prefix(2).joined(separator: " ")
            status = label(note, size: 12, alpha: 0.5)
        case let .failure(error)?:
            status = label(L("import.failed") + " " + error.localizedDescription, size: 12, alpha: 0.7)
        case nil:
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            status = NSStackView(views: [spinner, label(importStatus, size: 13, alpha: 0.55)])
        }
        let done = imported != nil
        return layout(title: L(done ? "onboarding.imported.title" : "onboarding.importing.title", chosen?.name ?? ""), text: nil,
                      body: stack([status, rows(of: cards, columns: 2)], spacing: 18),
                      buttons: done ? [button(L("onboarding.continue"), .light) { [weak self] in self?.advance() }] : [])
    }

    private static func symbol(of part: ImportPart) -> String {
        switch part {
        case .spaces: return "square.stack"
        case .tabs: return "pin"
        case .bookmarks: return "bookmark"
        case .history: return "clock"
        case .passwords: return "key"
        case .cookies: return "person.crop.circle"
        }
    }

    private func runImport() {
        // Return pressed twice, or Continue clicked again, mustn't start a second import over the first.
        guard !importing, imported == nil else { return }
        guard let source = chosen, let browser else { return advance() }
        if source.family == .safari, !SafariDirect.hasAccess() { return ImportWindowController.shared.show(selecting: source) }
        let profile = source.profiles.first(where: \.isDefault) ?? source.profiles.first
        importParts = ImportService.shared.parts(for: source, profile: profile)
        importing = true
        if let app = ImportService.shared.runningApp(of: source) {
            importStatus = L("import.progress.quitting", source.name)
            render(animated: true)
            ImportService.shared.quit(app) { [weak self] quit in
                guard let self else { return }
                importing = false
                if quit { return runImport() }
                imported = .failure(ImportQuitError(name: source.name))
                render(animated: false)
            }
            return
        }
        importStatus = L("import.progress.reading", source.name)
        render(animated: true)
        ImportService.shared.run(source: source, profile: profile, parts: Set(importParts), into: browser, progress: { [weak self] status in
            guard let self, importStatus != status else { return }
            importStatus = status
            render(animated: false)
        }) { [weak self] result in
            guard let self else { return }
            importing = false
            imported = result
            render(animated: false)
        }
    }

    private func lookView() -> NSView {
        let modes: [Space.Appearance] = [.light, .dark, .system]
        let titles = [L("theme.mode.light"), L("theme.mode.dark"), L("onboarding.mode.auto")]
        let current = browser?.space.appearance ?? .system
        var cards: [ChoiceCard] = []
        for (mode, title) in zip(modes, titles) {
            let card = ChoiceCard(icon: NSImage(systemSymbolName: mode == .light ? "sun.max" : mode == .dark ? "moon" : "circle.lefthalf.filled",
                                                accessibilityDescription: nil),
                                  title: title, detail: nil, mark: .radio, selected: mode == current, compact: true) { [weak self] in
                guard let self, let browser else { return }
                browser.space.appearance = mode == .system ? nil : mode
                browser.restyle(browser.space, color: nil, symbol: nil)
                cards.forEach { $0.selected = $0.title == title }
                art.show(.preview(browser.space), animated: false)
            }
            cards.append(card)
        }
        let swatches = NSStackView()
        swatches.spacing = 6
        func fill() {
            swatches.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for hex in SpaceStyle.palette {
                swatches.addArrangedSubview(OnboardingSwatch(hex: hex, selected: browser?.space.colorHex == hex) { [weak self] in
                    guard let self, let browser else { return }
                    browser.restyle(browser.space, color: hex, symbol: nil)
                    fill()
                    art.show(.preview(browser.space), animated: false)
                })
            }
        }
        fill()
        let icons = IconChoiceView(tileSize: 40, ring: .white)
        return layout(title: L("onboarding.look.title"), text: L("onboarding.look.text"),
                      body: stack([rows(of: cards, columns: 3), section(L("onboarding.look.color"), swatches),
                                   section(L("onboarding.look.icon"), icons)], spacing: 20),
                      buttons: [button(L("onboarding.continue"), .light) { [weak self] in self?.advance() }])
    }

    private func preferencesView() -> NSView {
        var cards: [NSView] = []
        if AdBlocker.isAvailable {
            cards.append(ChoiceCard(icon: nil, title: L("onboarding.adBlock.title"), detail: L("onboarding.adBlock.text"), mark: .check,
                                    selected: preferences.adBlock, toggles: true) { [weak self] in self?.preferences.adBlock.toggle() })
        }
        cards.append(ChoiceCard(icon: nil, title: L("onboarding.default.title"), detail: L("onboarding.default.text"), mark: .check,
                                selected: preferences.defaultBrowser, toggles: true) { [weak self] in self?.preferences.defaultBrowser.toggle() })
        cards.append(ChoiceCard(icon: nil, title: L("onboarding.login.title"), detail: L("onboarding.login.text"), mark: .check,
                                selected: preferences.atLogin, toggles: true) { [weak self] in self?.preferences.atLogin.toggle() })
        return layout(title: L("onboarding.preferences.title"), text: L("onboarding.preferences.text"), body: stack(cards, spacing: 10),
                      buttons: [button(L("onboarding.continue"), .light) { [weak self] in self?.applyPreferences(); self?.advance() }])
    }

    private func applyPreferences() {
        let adBlock = preferences.adBlock && AdBlocker.isAvailable
        browser?.updateSettings { $0.adBlock = adBlock }
        if preferences.defaultBrowser {
            for scheme in ["http", "https"] {
                NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme) { _ in }
            }
        }
        do {
            if preferences.atLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Trace.log("open at login: \(error)")
        }
    }

    private func readyView() -> NSView {
        let keys: [([String], String)] = [(["⌘", "T"], "empty.newTab"), (["⌘", "L"], "empty.openLocation"),
                                          (["⌘", "S"], "empty.toggleSidebar"), (["⌘", "D"], "empty.pin"),
                                          (["⌥", "⌘", "→"], "empty.nextSpace"), (["⇧", "⌘", "T"], "onboarding.reopen")]
        let rows = keys.map { ShortcutRow(title: L($0.1), keys: $0.0) as NSView }
        return layout(title: L("onboarding.ready.title"), text: L("onboarding.ready.text"), body: stack(rows, spacing: 8),
                      buttons: [button(L("onboarding.finish"), .light) { [weak self] in self?.finish() }])
    }

    // MARK: moving

    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return finish() }
        step = next
        render()
    }

    /// The last word, alone in the middle of the window, then the browser.
    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        guard let content = window?.contentView else { return }
        let splash = Splash(frame: content.bounds)
        splash.alphaValue = 0
        content.addSubview(splash)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.45
            splash.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.3
                    self?.window?.animator().alphaValue = 0
                }, completionHandler: { self?.window?.close(); splash.removeFromSuperview() })
            }
        })
    }

    private func complete() {
        let done = onFinish
        onFinish = nil
        done?()
    }

    // MARK: pieces

    /// A step: serif heading, a line of text, the body, and the buttons pinned to the bottom of the column.
    private func layout(title: String, text: String?, body: NSView, buttons: [OnboardingButton]) -> NSView {
        let container = NSView()
        let heading = NSTextField(wrappingLabelWithString: "")
        heading.attributedStringValue = NSAttributedString(string: title, attributes: [
            .font: NSFont.serif(32, .medium), .foregroundColor: NSColor.white, .kern: -0.3,
        ])
        heading.preferredMaxLayoutWidth = Self.column
        var top: [NSView] = [heading]
        if let text { top.append(label(text, size: 14, alpha: 0.55, lineHeight: 1.3)) }
        let head = stack(top, spacing: 12)
        let bar = NSStackView(views: buttons)
        bar.distribution = .fillEqually
        bar.spacing = 10
        primaryAction = { buttons.last?.perform() }
        for view in [head, body, bar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            head.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            head.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            head.topAnchor.constraint(equalTo: container.topAnchor),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            body.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            body.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 26),
            // The body never runs into the buttons, however much it holds.
            body.bottomAnchor.constraint(lessThanOrEqualTo: bar.topAnchor, constant: -24),
            // …and takes only the height it needs; otherwise the leftover went to its first row.
            { let snug = body.heightAnchor.constraint(equalToConstant: 0); snug.priority = .fittingSizeCompression; return snug }(),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 42),
        ])
        return container
    }

    private func stack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.setContentHuggingPriority(.required, for: .vertical)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func rows(of views: [NSView], columns: Int) -> NSView {
        let width = (Self.column - CGFloat(columns - 1) * 10) / CGFloat(columns)
        var rows: [NSView] = []
        for start in stride(from: 0, to: views.count, by: columns) {
            let row = NSStackView(views: Array(views[start..<min(start + columns, views.count)]))
            row.spacing = 10
            row.alignment = .top
            // Rows keep their cards' height; free space never goes to one of them.
            row.setContentHuggingPriority(.required, for: .vertical)
            row.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalToConstant: width).isActive = true }
            rows.append(row)
        }
        return stack(rows, spacing: 10)
    }

    private func section(_ title: String, _ control: NSView) -> NSView {
        stack([label(title, size: 12, alpha: 0.45), control], spacing: 10)
    }

    private func label(_ text: String, size: CGFloat, alpha: CGFloat, lineHeight: CGFloat = 1.2) -> NSTextField {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = lineHeight
        let field = NSTextField(wrappingLabelWithString: "")
        field.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.white.withAlphaComponent(alpha), .paragraphStyle: paragraph,
        ])
        field.preferredMaxLayoutWidth = Self.column
        return field
    }

    private func button(_ title: String, _ style: OnboardingButton.Style, action: @escaping () -> Void) -> OnboardingButton {
        let button = OnboardingButton(style: style)
        button.title = title
        button.action = action
        return button
    }

    private func icon(of source: BrowserSource) -> NSImage? {
        source.iconPath.flatMap { NSImage(contentsOfFile: $0) } ?? source.appPath.map { NSWorkspace.shared.icon(forFile: $0) }
    }
}

struct ImportQuitError: LocalizedError {
    let name: String
    var errorDescription: String? { L("import.quitFailed", name) }
}

private final class OnboardingWindow: NSWindow {
    var onReturn: (() -> Void)?
    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?() } else { super.keyDown(with: event) }
    }
}

extension NSFont {
    /// New York, Apple's serif, for display headings.
    static func serif(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }
}

#if DRIFT_DEV
extension OnboardingWindowController {
    /// The import step as it looks after a big import from Arc.
    func debugShowImported() {
        sources = ImportService.shared.sources()
        chosen = sources.first { $0.id == "arc" } ?? sources.first
        importParts = [.spaces, .bookmarks, .history, .passwords, .cookies]
        var summary = ImportSummary()
        (summary.spaces, summary.pins, summary.bookmarks, summary.history, summary.passwords, summary.cookies) = (2, 40, 4, 99_293, 117, 4_094)
        summary.warnings = [L("import.googleNote")]
        imported = .success(summary)
        step = .importing
        render(animated: false)
    }
}
#endif
