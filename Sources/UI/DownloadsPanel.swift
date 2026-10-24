import AppKit
import UniformTypeIdentifiers

/// The sidebar's downloads button: a ring that fills while something downloads, a dot once a download finished that
/// hasn't been looked at.
final class DownloadsButton: ChromeButton {
    /// 0…1 across active downloads; nil when none is running, -1 when their size isn't known yet.
    var progress: Double? {
        didSet {
            guard progress != oldValue else { return }
            if (progress == nil) != (oldValue == nil) { setSymbol(progress == nil ? "arrow.down.circle" : "arrow.down", size: progress == nil ? 14 : 9) }
            needsDisplay = true
        }
    }

    var unseen = false { didSet { if unseen != oldValue { needsDisplay = true } } }

    init() {
        super.init(symbol: "arrow.down.circle", tip: L("downloads.title"))
        setSymbol("arrow.down.circle", size: 14)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        if let progress {
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: 8.5, startAngle: 0, endAngle: 360)
            track.lineWidth = 2
            NSColor.secondaryLabelColor.withAlphaComponent(0.3).setStroke()
            track.stroke()
            let arc = NSBezierPath()
            let sweep = progress < 0 ? 0.25 : max(0.04, progress)
            arc.appendArc(withCenter: center, radius: 8.5, startAngle: 90, endAngle: 90 - 360 * sweep, clockwise: true)
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            NSColor.labelColor.withAlphaComponent(0.85).setStroke()
            arc.stroke()
        }
        if unseen {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.maxX - 8, y: bounds.maxY - 9, width: 6, height: 6)).fill()
        }
    }
}

/// The list behind the downloads button: what's downloading and what came down lately, newest first.
final class DownloadsPanel: NSViewController {
    private let isPrivate: Bool
    private let openURL: (String) -> Void
    private let list = NSStackView()
    private let scroll = ThinScrollView()
    private let empty = NSTextField(labelWithString: L("downloads.empty"))
    private let clear = NSButton()
    private var rows: [String: DownloadRow] = [:]
    private var observer: UUID?
    private var height: NSLayoutConstraint?

    static let width: CGFloat = 340
    private static let rowHeight: CGFloat = 56

    init(isPrivate: Bool, openURL: @escaping (String) -> Void) {
        self.isPrivate = isPrivate
        self.openURL = openURL
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { observer.map(Downloads.shared.stopObserving) }

    override func loadView() {
        let root = NSView()
        let title = NSTextField(labelWithString: L("downloads.title"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        clear.title = L("downloads.clear")
        clear.bezelStyle = .inline
        clear.isBordered = false
        clear.font = .systemFont(ofSize: 12)
        clear.contentTintColor = .secondaryLabelColor
        clear.target = self
        clear.action = #selector(clearTapped)
        let folder = NSButton(title: L("downloads.folder"), target: self, action: #selector(folderTapped))
        folder.bezelStyle = .inline
        folder.isBordered = false
        folder.font = .systemFont(ofSize: 12)
        folder.contentTintColor = .secondaryLabelColor
        folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        folder.imagePosition = .imageLeading

        list.orientation = .vertical
        list.spacing = 0
        list.alignment = .leading
        let document = FlippedView()
        document.addSubview(list)
        list.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        document.translatesAutoresizingMaskIntoConstraints = false

        empty.font = .systemFont(ofSize: 12)
        empty.textColor = .tertiaryLabelColor
        empty.alignment = .center

        let separator = NSBox()
        separator.boxType = .separator
        for view in [title, clear, scroll, empty, separator, folder] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let height = scroll.heightAnchor.constraint(equalToConstant: Self.rowHeight)
        self.height = height
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            clear.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            clear.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            height,
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            separator.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            folder.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
            folder.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            folder.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
        view = root
        observer = Downloads.shared.observe { [weak self] in self?.reload() }
        reload()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        Downloads.shared.markSeen()
    }

    private var items: [Downloads.Item] { Downloads.shared.items.filter { $0.offTheRecord == isPrivate } }

    private func reload() {
        let items = items
        var kept: [String: DownloadRow] = [:]
        var ordered: [DownloadRow] = []
        for item in items.prefix(50) {
            let row = rows[item.id] ?? DownloadRow(openURL: openURL)
            row.item = item
            kept[item.id] = row
            ordered.append(row)
        }
        if ordered.map(ObjectIdentifier.init) != list.arrangedSubviews.map(ObjectIdentifier.init) {
            list.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for row in ordered {
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
        }
        rows = kept
        empty.isHidden = !items.isEmpty
        clear.isHidden = !items.contains { !$0.active }
        height?.constant = max(Self.rowHeight, CGFloat(min(items.count, 6)) * Self.rowHeight)
        if view.window?.isVisible == true { Downloads.shared.markSeen() }
    }

    @objc private func clearTapped() {
        for item in items where !item.active { Downloads.shared.remove(item) }
    }

    @objc private func folderTapped() { NSWorkspace.shared.open(Downloads.folder) }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One download: the file's icon, its name, where it stands, and what can be done with it.
private final class DownloadRow: NSView, NSDraggingSource {
    var item: Downloads.Item? { didSet { if item != oldValue { update() } } }

    private let openURL: (String) -> Void
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let bar = ProgressLine()
    private let primary = ChromeButton(symbol: "magnifyingglass", tip: "", size: 12)
    private let secondary = ChromeButton(symbol: "xmark", tip: "", size: 11)
    private let keep = NSButton()
    private var iconPath: String?
    /// Where the name and status end: before whichever buttons the row shows.
    private var textEnd: [NSLayoutConstraint] = []
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressPoint: NSPoint?

    init(openURL: @escaping (String) -> Void) {
        self.openURL = openURL
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 56).isActive = true

        icon.imageScaling = .scaleProportionallyUpOrDown
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        name.maximumNumberOfLines = 1
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.maximumNumberOfLines = 1
        keep.title = L("downloads.keep")
        keep.bezelStyle = .push
        keep.controlSize = .small
        keep.font = .systemFont(ofSize: 11)
        keep.target = self
        keep.action = #selector(keepTapped)
        primary.target = self
        primary.action = #selector(primaryTapped)
        secondary.target = self
        secondary.action = #selector(secondaryTapped)

        for view in [icon, name, status, bar, keep, primary, secondary] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            status.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            status.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            bar.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: primary.leadingAnchor, constant: -8),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            bar.heightAnchor.constraint(equalToConstant: 3),
            secondary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            secondary.centerYAnchor.constraint(equalTo: centerYAnchor),
            secondary.widthAnchor.constraint(equalToConstant: 24),
            secondary.heightAnchor.constraint(equalToConstant: 24),
            primary.trailingAnchor.constraint(equalTo: secondary.leadingAnchor, constant: -2),
            primary.centerYAnchor.constraint(equalTo: centerYAnchor),
            primary.widthAnchor.constraint(equalToConstant: 24),
            primary.heightAnchor.constraint(equalToConstant: 24),
            keep.trailingAnchor.constraint(equalTo: secondary.leadingAnchor, constant: -4),
            keep.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        guard let item else { return }
        name.stringValue = item.filename
        name.textColor = item.state == .cancelled || item.state == .failed ? .secondaryLabelColor : .labelColor
        status.stringValue = Self.status(of: item)
        status.textColor = item.dangerous && item.active ? .systemOrange : .secondaryLabelColor
        if iconPath != item.path || item.state == .finished && icon.image == nil {
            iconPath = item.path
            icon.image = item.exists && item.state == .finished
                ? NSWorkspace.shared.icon(forFile: item.path)
                : NSWorkspace.shared.icon(for: UTType(filenameExtension: (item.filename as NSString).pathExtension) ?? .data)
        }
        icon.alphaValue = item.state == .finished ? 1 : 0.55
        defer { placeTextEnd() }
        bar.isHidden = !item.active || item.dangerous
        bar.fraction = item.fraction
        bar.paused = item.paused
        keep.isHidden = !(item.dangerous && item.active)

        switch (item.state, item.dangerous) {
        case (.downloading, true):
            primary.isHidden = true
            secondary.setSymbol("xmark", size: 11)
            secondary.toolTip = L("downloads.discard")
        case (.downloading, false):
            primary.isHidden = false
            primary.setSymbol(item.paused ? "play.fill" : "pause.fill", size: 10)
            primary.toolTip = L(item.paused ? "downloads.resume" : "downloads.pause")
            secondary.setSymbol("xmark", size: 11)
            secondary.toolTip = L("downloads.cancel")
        case (.finished, _):
            primary.isHidden = true
            secondary.setSymbol("magnifyingglass", size: 12)
            secondary.toolTip = L("downloads.reveal")
        case (.cancelled, _), (.failed, _):
            primary.isHidden = true
            secondary.setSymbol("arrow.clockwise", size: 12)
            secondary.toolTip = L("downloads.retry")
        }
    }

    private func placeTextEnd() {
        let edge = !keep.isHidden ? keep.leadingAnchor : !primary.isHidden ? primary.leadingAnchor : secondary.leadingAnchor
        NSLayoutConstraint.deactivate(textEnd)
        textEnd = [name.trailingAnchor.constraint(lessThanOrEqualTo: edge, constant: -6),
                   status.trailingAnchor.constraint(lessThanOrEqualTo: edge, constant: -6)]
        NSLayoutConstraint.activate(textEnd)
    }

    static func status(of item: Downloads.Item) -> String {
        func size(_ value: Double) -> String { Self.bytes(value) }
        switch item.state {
        case .downloading:
            if item.dangerous { return L("downloads.dangerous") }
            let amount = item.total > 0 ? L("downloads.ofTotal", size(item.received), size(item.total)) : size(item.received)
            if item.paused { return L("downloads.paused") + " · " + amount }
            guard item.speed > 0 else { return amount }
            // Size, then time left when it can be told, else the speed: one short line.
            guard item.total > 0 else { return amount + " · " + size(item.speed) + L("downloads.perSecond") }
            let left = DateComponentsFormatter()
            var calendar = Calendar.current
            calendar.locale = Locale(identifier: L10n.code)
            left.calendar = calendar
            left.unitsStyle = .abbreviated
            left.maximumUnitCount = 1
            left.allowedUnits = [.hour, .minute, .second]
            guard let text = left.string(from: max(1, (item.total - item.received) / item.speed)) else { return amount }
            return amount + " · " + L("downloads.left", text)
        case .finished:
            let total = size(item.total > 0 ? item.total : item.received)
            return item.exists ? total : total + " · " + L("downloads.missing")
        case .cancelled:
            return L("downloads.cancelled")
        case .failed:
            return L("downloads.failed")
        }
    }

    /// File sizes in the interface's language, whatever the system's (ByteCountFormatter only follows the system).
    static func bytes(_ value: Double) -> String {
        let units = L("downloads.units").components(separatedBy: ",")
        var amount = max(0, value)
        var unit = 0
        while amount >= 1000, unit < units.count - 1 {
            amount /= 1000
            unit += 1
        }
        let number = NumberFormatter()
        number.locale = Locale(identifier: L10n.code)
        number.maximumFractionDigits = unit >= 2 && amount < 100 ? 1 : 0
        number.minimumFractionDigits = 0
        return "\(number.string(from: amount as NSNumber) ?? "\(Int(amount))") \(units[unit])"
    }

    // MARK: actions

    @objc private func primaryTapped() {
        guard let item else { return }
        if item.paused { Downloads.shared.resume(item) } else { Downloads.shared.pause(item) }
    }

    @objc private func secondaryTapped() {
        guard let item else { return }
        switch item.state {
        case .downloading: Downloads.shared.cancel(item)
        case .finished: Downloads.shared.reveal(item)
        case .cancelled, .failed:
            Downloads.shared.remove(item)
            openURL(item.url)
        }
    }

    @objc private func keepTapped() {
        guard let item else { return }
        Downloads.shared.keep(item)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item else { return nil }
        let menu = NSMenu()
        if item.state == .finished {
            menu.addItem(ClosureMenuItem(L("downloads.open")) { Downloads.shared.open(item) })
            menu.addItem(ClosureMenuItem(L("downloads.reveal")) { Downloads.shared.reveal(item) })
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem(L("downloads.copyLink")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.url, forType: .string)
        })
        if !item.active {
            menu.addItem(ClosureMenuItem(L("downloads.remove")) { Downloads.shared.remove(item) })
        }
        return menu
    }

    // MARK: hover, open, drag out

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        Theme.hover.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 8, yRadius: 8).fill()
    }

    override func mouseDown(with event: NSEvent) { pressPoint = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressPoint, let item, item.state == .finished, item.exists, let url = item.fileURL,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
        pressPoint = nil
        let drag = NSDraggingItem(pasteboardWriter: url as NSURL)
        drag.setDraggingFrame(convert(icon.frame, from: icon.superview), contents: icon.image)
        beginDraggingSession(with: [drag], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressPoint = nil }
        guard pressPoint != nil, let item, item.state == .finished else { return }
        Downloads.shared.open(item)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .link, .generic] : []
    }
}

/// A thin capsule that fills as the download comes in; paused, it greys out.
private final class ProgressLine: NSView {
    var fraction: Double? { didSet { needsDisplay = true } }
    var paused = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.secondaryLabelColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let filled = NSRect(x: 0, y: 0, width: max(bounds.height, bounds.width * (fraction ?? 0.15)), height: bounds.height)
        (paused ? NSColor.tertiaryLabelColor : NSColor.controlAccentColor).setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}
