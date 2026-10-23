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
        let divider = Hairline()
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
            let note = summary.lines.isEmpty ? L("import.done.empty") : summary.warnings.prefix(2).joined(separator: " ")
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
                swatches.addArrangedSubview(Swatch(hex: hex, selected: browser?.space.colorHex == hex) { [weak self] in
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
        if let browser {
            browser.state.settings.adBlock = preferences.adBlock && AdBlocker.isAvailable
            browser.settingsChanged()
        }
        if preferences.defaultBrowser {
            for scheme in ["http", "https"] {
                NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme) { _ in }
            }
        }
        if preferences.atLogin { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
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

// MARK: - The mark

/// The logo's flower as a path (from Resources/Logos), drawn at any size and colour.
enum Mark {
    /// The flower in the logos' 325-point square.
    static let path: NSBezierPath = {
        let d = "M162.5 140.756C136.388 120.988 138.396 89.3605 162.5 77.5C186.604 89.3605 188.612 120.988 162.5 140.756C182.586 118.023 213.72 107.151 231.798 118.023C255.901 130.872 249.875 156.57 229.789 172.384C219.746 181.279 204.681 183.256 189.616 181.279C208.698 190.174 216.733 208.953 208.698 222.791C195.642 232.674 181.582 219.826 177.565 206.977C179.573 229.709 172.543 241.57 162.5 247.5C152.457 241.57 145.427 229.709 147.435 206.977C143.418 219.826 129.358 232.674 116.302 222.791C108.267 208.953 116.302 190.174 135.384 181.279C120.319 183.256 105.254 181.279 95.211 172.384C75.1247 156.57 69.0988 130.872 93.2023 118.023C111.28 107.151 142.414 118.023 162.5 140.756Z"
        let path = NSBezierPath()
        let scanner = Scanner(string: d)
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: " ,")
        var command = "M"
        func point() -> NSPoint? {
            guard let x = scanner.scanDouble(), let y = scanner.scanDouble() else { return nil }
            return NSPoint(x: x, y: 325 - y)
        }
        while !scanner.isAtEnd {
            if let letter = scanner.scanCharacters(from: CharacterSet(charactersIn: "MCZ")) { command = String(letter.last!) }
            switch command {
            case "M": if let p = point() { path.move(to: p) }
            case "C":
                guard let a = point(), let b = point(), let c = point() else { break }
                path.curve(to: c, controlPoint1: a, controlPoint2: b)
            default:
                path.close()
                _ = scanner.scanCharacters(from: CharacterSet(charactersIn: "Z"))
            }
        }
        return path
    }()

    /// The flower scaled to fill `rect` (keeping its own proportions inside the logo's square).
    static func path(in rect: NSRect) -> NSBezierPath {
        let copy = path.copy() as! NSBezierPath
        let bounds = copy.bounds
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        var transform = AffineTransform(translationByX: rect.midX, byY: rect.midY)
        transform.scale(scale)
        transform.translate(x: -bounds.midX, y: -bounds.midY)
        copy.transform(using: transform)
        return copy
    }
}

// MARK: - The painting

/// The right half: an abstract painting in the step's colours, feathered into the black on its left, with the
/// step's motif on top.
private final class ArtPanel: NSView {
    enum Scene: Equatable {
        case bloom, orbit, dock
        case source(BrowserSource)
        case preview(Space?)

        static func == (a: Scene, b: Scene) -> Bool {
            switch (a, b) {
            case (.bloom, .bloom), (.orbit, .orbit), (.dock, .dock): return true
            case let (.source(x), .source(y)): return x.id == y.id
            case (.preview, .preview): return true
            default: return false
            }
        }
    }

    private let canvas = CALayer()
    private let motif = MotifView()
    private var scene: Scene?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        canvas.contentsGravity = .resizeAspectFill
        canvas.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        canvas.frame = bounds
        layer?.addSublayer(canvas)
        let feather = CAGradientLayer()
        feather.colors = [NSColor.black.cgColor, NSColor.black.withAlphaComponent(0).cgColor]
        feather.startPoint = CGPoint(x: 0, y: 0.5)
        feather.endPoint = CGPoint(x: 0.42, y: 0.5)
        feather.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        feather.frame = bounds
        layer?.addSublayer(feather)
        motif.frame = bounds
        motif.autoresizingMask = [.width, .height]
        addSubview(motif)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ next: Scene, animated: Bool) {
        let palette = Painting.palette(for: next)
        if scene == nil || Painting.palette(for: scene!) != palette {
            let image = Painting.image(palette: palette, size: bounds.size)
            if animated {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.6
                canvas.add(fade, forKey: "paint")
            }
            canvas.contents = image
        }
        scene = next
        motif.scene = next
        if animated {
            motif.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.6
                motif.animator().alphaValue = 1
            }
        }
    }
}

/// Paintings made, not shipped: soft broad strokes in a few colours, blurred, then a dry-brush grain over them.
private enum Painting {
    struct Palette: Equatable {
        let ground: NSColor
        let strokes: [NSColor]
        let seed: UInt64
    }

    static func palette(for scene: ArtPanel.Scene) -> Palette {
        func rgb(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        switch scene {
        case .bloom: return Palette(ground: rgb(0x120A1C), strokes: [rgb(0x5B2A86), rgb(0xA62BFF), rgb(0x2A1B4A), rgb(0xE07AB8), rgb(0x1C2C55)], seed: 7)
        case .orbit, .source: return Palette(ground: rgb(0x0B1614), strokes: [rgb(0x1F4D45), rgb(0x3E7F6E), rgb(0x16302B), rgb(0x8FB8A6), rgb(0x24423C)], seed: 19)
        case .preview: return Palette(ground: rgb(0x1A120E), strokes: [rgb(0x8C4A32), rgb(0xC9775A), rgb(0x3A2420), rgb(0xE8B49A), rgb(0x5A3A2E)], seed: 31)
        case .dock: return Palette(ground: rgb(0x16130A), strokes: [rgb(0x8A6A1E), rgb(0xE0B640), rgb(0x3B3220), rgb(0xF2DFA0), rgb(0x5C4B22)], seed: 43)
        }
    }

    private struct Random {
        var state: UInt64
        mutating func next() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(state >> 33) / CGFloat(1 << 31)
        }
    }

    static func image(palette: Palette, size: NSSize) -> CGImage? {
        let scale: CGFloat = 2
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(palette.ground.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var random = Random(state: palette.seed)
        context.setLineCap(.round)
        for index in 0..<64 {
            let color = palette.strokes[index % palette.strokes.count]
            context.setStrokeColor(color.withAlphaComponent(0.18 + random.next() * 0.45).cgColor)
            context.setLineWidth((24 + random.next() * 120) * scale)
            let start = CGPoint(x: random.next() * CGFloat(width), y: random.next() * CGFloat(height))
            let angle = random.next() * .pi * 2
            let length = (120 + random.next() * 380) * scale
            let end = CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
            let bend = CGPoint(x: (start.x + end.x) / 2 + (random.next() - 0.5) * length, y: (start.y + end.y) / 2 + (random.next() - 0.5) * length)
            context.move(to: start)
            context.addQuadCurve(to: end, control: bend)
            context.strokePath()
        }
        guard let strokes = context.makeImage() else { return nil }
        let base = CIImage(cgImage: strokes)
        let soft = base.clampedToExtent().applyingGaussianBlur(sigma: 12).cropped(to: base.extent)
        // Bristle marks: fine noise smeared a little along a slant, barely laid over the paint.
        let bristles = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: 9, kCIInputAngleKey: 0.6 + Double(palette.seed % 5) * 0.5])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.3, kCIInputBrightnessKey: -0.1])
            .cropped(to: base.extent)
        let painted = bristles.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: soft])
            .applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: soft, "inputTime": 0.72])
        // Canvas: a coarse, soft tooth under everything.
        let tooth = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .transformed(by: CGAffineTransform(scaleX: 3, y: 3))
            .applyingGaussianBlur(sigma: 1.2)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputBrightnessKey: -0.35])
            .cropped(to: base.extent)
        let finished = tooth.applyingFilter("CIOverlayBlendMode", parameters: [kCIInputBackgroundImageKey: painted])
            .applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: painted, "inputTime": 0.8])
            .applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: 0.9, kCIInputRadiusKey: 2.2])
        return CIContext().createCGImage(finished, from: base.extent)
    }
}

/// What sits on the painting: the flower, the things an import brings, the browser in its new look, the Dock.
private final class MotifView: NSView {
    var scene: ArtPanel.Scene? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let scene else { return }
        let center = NSPoint(x: bounds.midX + 40, y: bounds.midY)
        switch scene {
        case .bloom:
            drawFlower(in: NSRect(x: center.x - 110, y: center.y - 110, width: 220, height: 220), color: .white, glow: 0.35)
        case .orbit:
            for radius: CGFloat in [96, 140, 186] {
                NSColor.white.withAlphaComponent(0.09).setStroke()
                let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                ring.lineWidth = 1
                ring.stroke()
            }
            drawFlower(in: NSRect(x: center.x - 62, y: center.y - 62, width: 124, height: 124), color: .white, glow: 0.3)
            let badges: [(String, CGFloat, CGFloat, CGFloat)] = [("key.fill", 140, 128, 30), ("bookmark.fill", 186, 38, 38),
                                                                  ("clock.fill", 140, -12, 22), ("puzzlepiece.extension.fill", 186, 200, 28),
                                                                  ("folder.fill", 186, 285, 34)]
            for (symbol, radius, degrees, size) in badges {
                let angle = degrees * .pi / 180
                drawBadge(symbol, at: NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius), size: size)
            }
        case let .source(source):
            let image = source.iconPath.flatMap { NSImage(contentsOfFile: $0) } ?? source.appPath.map { NSWorkspace.shared.icon(forFile: $0) }
            for index in 0..<5 {
                NSColor.white.withAlphaComponent(0.2 + CGFloat(index) * 0.16).setFill()
                let size: CGFloat = 5 + CGFloat(index)
                NSBezierPath(ovalIn: NSRect(x: center.x - size / 2, y: center.y + 160 - CGFloat(index) * 28, width: size, height: size)).fill()
            }
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.shadowBlurRadius = 30
            shadow.shadowOffset = NSSize(width: 0, height: -12)
            shadow.set()
            image?.draw(in: NSRect(x: center.x - 90, y: center.y - 150, width: 180, height: 180))
            NSGraphicsContext.restoreGraphicsState()
        case let .preview(space):
            drawBrowser(in: NSRect(x: center.x - 190, y: center.y - 120, width: 380, height: 240), space: space)
        case .dock:
            let strip = NSRect(x: center.x - 170, y: center.y - 70, width: 340, height: 120)
            NSColor.white.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: strip, xRadius: 30, yRadius: 30).fill()
            NSColor.white.withAlphaComponent(0.18).setStroke()
            NSBezierPath(roundedRect: strip.insetBy(dx: 0.5, dy: 0.5), xRadius: 30, yRadius: 30).stroke()
            for (index, x) in [-118, 118].enumerated() {
                NSColor.white.withAlphaComponent(0.1 + CGFloat(index) * 0.04).setFill()
                NSBezierPath(roundedRect: NSRect(x: center.x + CGFloat(x) - 40, y: center.y - 50, width: 80, height: 80), xRadius: 18, yRadius: 18).fill()
            }
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            shadow.shadowBlurRadius = 24
            shadow.shadowOffset = NSSize(width: 0, height: -10)
            shadow.set()
            IconChoice.image(IconChoice.current)?.draw(in: NSRect(x: center.x - 74, y: center.y - 58, width: 148, height: 148))
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.withAlphaComponent(0.8).setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 3, y: center.y - 66, width: 6, height: 6)).fill()
        }
    }

    private func drawFlower(in rect: NSRect, color: NSColor, glow: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.white.withAlphaComponent(glow)
        shadow.shadowBlurRadius = 60
        shadow.set()
        color.withAlphaComponent(0.94).setFill()
        Mark.path(in: rect).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawBadge(_ symbol: String, at point: NSPoint, size: CGFloat) {
        let rect = NSRect(x: point.x - size, y: point.y - size, width: size * 2, height: size * 2)
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size * 0.72, weight: .semibold).applying(.init(paletteColors: [NSColor(white: 0.75, alpha: 1)])))
        else { return }
        let glyph = image.size
        image.draw(in: NSRect(x: point.x - glyph.width / 2, y: point.y - glyph.height / 2, width: glyph.width, height: glyph.height))
    }

    private func drawBrowser(in rect: NSRect, space: Space?) {
        let dark: Bool = {
            switch space?.appearance ?? .system {
            case .dark: return true
            case .light: return false
            case .system: return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
            }
        }()
        let tint = NSColor(hex: space?.colorHex ?? SpaceStyle.palette[0])
        let shape = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 34
        shadow.shadowOffset = NSSize(width: 0, height: -14)
        shadow.set()
        (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        tint.withAlphaComponent(0.3).setFill()
        rect.fill(using: .sourceOver)
        let ink: NSColor = dark ? .white : .black
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.minX + 14 + CGFloat(index) * 13, y: rect.maxY - 20, width: 8, height: 8)).fill()
        }
        for index in 0..<6 {
            let y = rect.maxY - 54 - CGFloat(index) * 24
            if index == 1 {
                (dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.white.withAlphaComponent(0.85)).setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.minX + 8, y: y - 9, width: 100, height: 20), xRadius: 6, yRadius: 6).fill()
            }
            ink.withAlphaComponent(index == 1 ? 0.55 : 0.28).setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX + 18, y: y - 2, width: [62, 48, 70, 40, 56, 50][index], height: 4), xRadius: 2, yRadius: 2).fill()
        }
        let page = NSRect(x: rect.minX + 118, y: rect.minY + 8, width: rect.width - 126, height: rect.height - 16)
        (dark ? NSColor(white: 0.09, alpha: 1) : .white).setFill()
        NSBezierPath(roundedRect: page, xRadius: 9, yRadius: 9).fill()
        ink.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: NSRect(x: page.minX + 18, y: page.maxY - 32, width: 110, height: 9), xRadius: 4.5, yRadius: 4.5).fill()
        for (index, fraction) in [0.84, 0.7, 0.9, 0.6, 0.78].enumerated() {
            ink.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: NSRect(x: page.minX + 18, y: page.maxY - 56 - CGFloat(index) * 16, width: (page.width - 36) * fraction, height: 5),
                         xRadius: 2.5, yRadius: 2.5).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

private final class Splash: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let mark = NSRect(x: bounds.midX - 36, y: bounds.midY + 40, width: 72, height: 72)
        NSColor(srgbRed: 0.65, green: 0.17, blue: 1, alpha: 1).setFill()
        Mark.path(in: mark).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = NSAttributedString(string: L("onboarding.splash"), attributes: [
            .font: NSFont.serif(44, .regular), .foregroundColor: NSColor.white.withAlphaComponent(0.9), .paragraphStyle: paragraph,
        ])
        let rect = text.boundingRect(with: NSSize(width: bounds.width - 160, height: 400), options: [.usesLineFragmentOrigin])
        text.draw(with: NSRect(x: 80, y: bounds.midY - 20 - rect.height, width: bounds.width - 160, height: rect.height), options: [.usesLineFragmentOrigin])
    }
}

private final class ProgressBar: NSView {
    private let fill = CAGradientLayer()
    private var fraction: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fill.colors = [NSColor(srgbRed: 0.65, green: 0.17, blue: 1, alpha: 1).cgColor,
                       NSColor(srgbRed: 1, green: 0.36, blue: 0.71, alpha: 1).cgColor,
                       NSColor(srgbRed: 1, green: 0.36, blue: 0.71, alpha: 0).cgColor]
        fill.locations = [0, 0.85, 1]
        fill.startPoint = CGPoint(x: 0, y: 0.5)
        fill.endPoint = CGPoint(x: 1, y: 0.5)
        fill.cornerRadius = 3
        layer?.addSublayer(fill)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(fraction: CGFloat, animated: Bool) {
        self.fraction = fraction
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.6 : 0)
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1))
        fill.frame = NSRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        set(fraction: fraction, animated: false)
    }
}

// MARK: - Controls

final class OnboardingButton: NSView {
    enum Style { case light, dark, link }

    private let style: Style
    var title = "" { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var action: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var font: NSFont { style == .link ? .systemFont(ofSize: 12, weight: .medium) : .systemFont(ofSize: 13, weight: .semibold) }

    override var intrinsicContentSize: NSSize {
        let width = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        return style == .link ? NSSize(width: width, height: 20) : NSSize(width: width + 60, height: 42)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        var text = NSColor.white
        switch style {
        case .light:
            NSColor(white: pressed ? 0.7 : hovering ? 0.9 : 0.85, alpha: 1).setFill()
            shape.fill()
            text = NSColor(white: 0.08, alpha: 1)
        case .dark:
            NSColor(white: pressed ? 0.2 : hovering ? 0.16 : 0.12, alpha: 1).setFill()
            shape.fill()
            text = NSColor(white: 0.62, alpha: 1)
        case .link:
            text = .white.withAlphaComponent(hovering ? 0.8 : 0.42)
        }
        let string = NSMutableAttributedString(string: title, attributes: [.font: font, .foregroundColor: text])
        if style == .light {
            string.append(NSAttributedString(string: "  ↩", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: text.withAlphaComponent(0.45)]))
        }
        let size = string.size()
        string.draw(at: NSPoint(x: style == .link ? 0 : (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    func perform() {
        guard !isHidden, window != nil else { return }
        action?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = isUnderPointer }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { perform() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A rounded card with a hairline: an option with a radio or a checkbox, or an import part with its progress.
private final class ChoiceCard: NSView {
    enum Mark { case radio, check, done, busy, none }

    let title: String
    private let mark: Mark
    private let toggles: Bool
    private let action: () -> Void
    private let spinner = NSProgressIndicator()
    var selected: Bool { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }

    init(icon: NSImage?, title: String, detail: String?, mark: Mark, selected: Bool, compact: Bool = false, toggles: Bool = false,
         action: @escaping () -> Void) {
        self.title = title
        self.mark = mark
        self.selected = selected
        self.toggles = toggles
        self.action = action
        super.init(frame: .zero)
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.textColor = .white.withAlphaComponent(0.92)
        name.lineBreakMode = .byTruncatingTail
        var texts: [NSView] = [name]
        if let detail, compact {
            let info = NSTextField(labelWithString: detail)
            info.font = .systemFont(ofSize: 12)
            info.textColor = .white.withAlphaComponent(0.5)
            info.lineBreakMode = .byTruncatingTail
            texts.append(info)
        } else if let detail {
            let info = NSTextField(wrappingLabelWithString: detail)
            info.font = .systemFont(ofSize: 12)
            info.textColor = .white.withAlphaComponent(0.45)
            info.preferredMaxLayoutWidth = 330
            texts.append(info)
        }
        let text = NSStackView(views: texts)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        var views: [NSView] = []
        if let icon {
            let image = NSImageView(image: icon)
            image.imageScaling = .scaleProportionallyUpOrDown
            if icon.isTemplate { image.contentTintColor = .white.withAlphaComponent(0.8) }
            image.widthAnchor.constraint(equalToConstant: compact ? 18 : 26).isActive = true
            image.heightAnchor.constraint(equalToConstant: compact ? 18 : 26).isActive = true
            views.append(image)
        }
        views.append(text)
        let row = NSStackView(views: views)
        row.spacing = 12
        row.alignment = .centerY
        let leading: CGFloat = mark == .check ? 46 : 16
        for view in [row, spinner] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = mark != .busy
        if mark == .busy { spinner.startAnimation(nil) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: compact ? 50 : 60),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -44),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 12),
            spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentHuggingPriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        NSColor(white: hovering ? 0.1 : 0.075, alpha: 1).setFill()
        shape.fill()
        NSColor.white.withAlphaComponent(selected && mark == .radio ? 0.5 : 0.14).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        switch mark {
        case .radio:
            let ring = NSRect(x: bounds.maxX - 36, y: bounds.midY - 10, width: 20, height: 20)
            if selected {
                NSColor.white.setFill()
                NSBezierPath(ovalIn: ring).fill()
                NSColor.black.setFill()
                NSBezierPath(ovalIn: ring.insetBy(dx: 3, dy: 3)).fill()
                NSColor.white.setFill()
                NSBezierPath(ovalIn: ring.insetBy(dx: 5.5, dy: 5.5)).fill()
            } else {
                NSColor.white.withAlphaComponent(0.35).setStroke()
                let path = NSBezierPath(ovalIn: ring.insetBy(dx: 0.75, dy: 0.75))
                path.lineWidth = 1.5
                path.stroke()
            }
        case .check:
            let box = NSRect(x: 16, y: bounds.midY - 10, width: 20, height: 20)
            let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
            if selected {
                NSColor.white.setFill()
                path.fill()
                drawTick(in: box, color: .black)
            } else {
                NSColor.white.withAlphaComponent(0.35).setStroke()
                path.lineWidth = 1.5
                path.stroke()
            }
        case .done:
            let disc = NSRect(x: bounds.maxX - 36, y: bounds.midY - 10, width: 20, height: 20)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: disc).fill()
            drawTick(in: disc, color: .black)
        case .busy, .none:
            break
        }
    }

    private func drawTick(in box: NSRect, color: NSColor) {
        let tick = NSBezierPath()
        tick.move(to: NSPoint(x: box.minX + 5.5, y: box.midY))
        tick.line(to: NSPoint(x: box.minX + 8.5, y: box.minY + 6))
        tick.line(to: NSPoint(x: box.maxX - 5, y: box.maxY - 6))
        tick.lineWidth = 2
        tick.lineCapStyle = .round
        tick.lineJoinStyle = .round
        color.setStroke()
        tick.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard mark == .radio || mark == .check else { return }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = isUnderPointer }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {
        guard mark == .radio || mark == .check else { return }
        if toggles { selected.toggle() }
        action()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
}

private final class FeatureRow: NSStackView {
    init(symbol: String, text: String) {
        super.init(frame: .zero)
        let badge = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))!)
        badge.contentTintColor = .white.withAlphaComponent(0.75)
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 9
        badge.layer?.borderWidth = 1
        badge.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        badge.widthAnchor.constraint(equalToConstant: 32).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 14)
        label.textColor = .white.withAlphaComponent(0.72)
        label.preferredMaxLayoutWidth = 380
        setViews([badge, label], in: .leading)
        spacing = 14
        alignment = .centerY
    }

    required init?(coder: NSCoder) { fatalError() }
}

private final class Hairline: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 440, height: 1) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.12).setFill()
        bounds.fill()
    }
}

/// Keys drawn as keys: lit from above, a hairline edge and a darker lip at the bottom.
final class KeyCaps: NSView {
    private let keys: [String]
    private let font = NSFont.systemFont(ofSize: 12, weight: .medium)

    init(keys: [String]) {
        self.keys = keys
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func width(of key: String) -> CGFloat {
        max(22, ceil((key as NSString).size(withAttributes: [.font: font]).width) + 12)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: keys.map(width).reduce(0, +) + CGFloat(max(0, keys.count - 1)) * 4, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 0
        for key in keys {
            let rect = NSRect(x: x, y: 0, width: width(of: key), height: bounds.height)
            NSColor(white: 0.05, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            let face = NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY + 1.5, width: rect.width, height: rect.height - 1.5),
                                    xRadius: 5, yRadius: 5)
            NSGradient(colors: [NSColor(white: 0.24, alpha: 1), NSColor(white: 0.17, alpha: 1)])!.draw(in: face, angle: -90)
            NSColor.white.withAlphaComponent(0.1).setStroke()
            face.lineWidth = 1
            face.stroke()
            let text = NSAttributedString(string: key, attributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.85)])
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.minY + 1.5 + (rect.height - 1.5 - size.height) / 2))
            x = rect.maxX + 4
        }
    }
}

private final class ShortcutRow: NSView {
    init(title: String, keys: [String]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.backgroundColor = NSColor(white: 0.075, alpha: 1).cgColor
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .white.withAlphaComponent(0.85)
        let caps = KeyCaps(keys: keys)
        for view in [label, caps] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 440),
            heightAnchor.constraint(equalToConstant: 42),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            caps.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            caps.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

private final class Swatch: NSView {
    private let color: NSColor
    private let selected: Bool
    private let action: () -> Void

    init(hex: String, selected: Bool, action: @escaping () -> Void) {
        color = NSColor(hex: hex)
        self.selected = selected
        self.action = action
        super.init(frame: .zero)
        toolTip = SpaceStyle.colorName(hex)
        widthAnchor.constraint(equalToConstant: 26).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if selected {
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 1.5
            ring.stroke()
        }
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 5, dy: 5)).fill()
    }

    override func mouseDown(with event: NSEvent) { action() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
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
