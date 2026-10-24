import AppKit
import ArchideaCore

final class AddressPill: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The whole address, not just the host (Settings › site controls › Show Full URL).
    static var showsFullURL = false

    var onClick: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSiteControls: ((NSView) -> Void)?
    private let lock = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let copyButton = ChromeButton(symbol: "link", tip: L("address.copy.tip"), size: 12)
    private let siteButton = ChromeButton(symbol: "slider.horizontal.3", tip: L("address.site.tip"), size: 12)
    private var hovering = false { didSet { needsDisplay = true } }
    private var hasPage = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        lock.contentTintColor = .secondaryLabelColor
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        siteButton.target = self
        siteButton.action = #selector(siteTapped)
        [lock, label, copyButton, siteButton].forEach(addSubview)
        show(url: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(url: String?) {
        guard let url, !url.isEmpty, url != "about:blank" else {
            hasPage = false
            label.stringValue = L("address.placeholder")
            label.textColor = .tertiaryLabelColor
            lock.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            toolTip = nil
            needsLayout = true
            return
        }
        hasPage = true
        let parsed = URL(string: url)
        var host = parsed?.host ?? url
        if host.hasPrefix("www.") { host.removeFirst(4) }
        label.stringValue = Self.showsFullURL ? url : host
        label.lineBreakMode = Self.showsFullURL ? .byTruncatingMiddle : .byTruncatingTail
        label.textColor = .labelColor
        let secure = parsed?.scheme == "https"
        lock.image = NSImage(systemSymbolName: secure ? "lock.fill" : "info.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        toolTip = url
        needsLayout = true
    }

    /// A short confirmation on the copy button.
    func flashCopied() {
        copyButton.setSymbol("checkmark", size: 12)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.copyButton.setSymbol("link", size: 12) }
    }

    override func layout() {
        super.layout()
        copyButton.isHidden = !hasPage
        siteButton.isHidden = !hasPage
        siteButton.frame = NSRect(x: bounds.width - 32, y: (bounds.height - 26) / 2, width: 26, height: 26)
        copyButton.frame = NSRect(x: bounds.width - 60, y: (bounds.height - 26) / 2, width: 26, height: 26)
        lock.frame = NSRect(x: 12, y: (bounds.height - 14) / 2, width: 14, height: 14)
        let right = hasPage ? copyButton.frame.minX - 4 : bounds.width - 12
        label.frame = NSRect(x: 32, y: (bounds.height - 17) / 2, width: max(0, right - 32), height: 17)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let hit, hit === copyButton || hit === siteButton { return hit }
        return hit == nil ? nil : self
    }

    override func draw(_ dirtyRect: NSRect) {
        (hovering ? Theme.addressHover : Theme.addressFill).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = isUnderPointer }
    override func mouseMoved(with event: NSEvent) { if hovering != isUnderPointer { hovering.toggle() } }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onClick?() }

    @objc private func copyTapped() { onCopy?() }
    @objc private func siteTapped() { onSiteControls?(siteButton) }
}
