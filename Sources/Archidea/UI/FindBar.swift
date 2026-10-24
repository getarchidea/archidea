import AppKit
import ArchideaCore
import ArdiaCore

/// Find on page: a compact floating bar at the page's top right. Return finds the next match,
/// Shift-Return the previous one, Escape closes.
final class FindBar: NSView, NSTextFieldDelegate {
    private weak var controller: BrowserWindowController?
    private weak var tab: ArdiaCoreTab?
    private let card = NSView()
    private let glass = NSImageView()
    private let field = NSTextField()
    private let count = NSTextField(labelWithString: "")
    private let previous = ChromeButton(symbol: "chevron.up", tip: L("find.previous"), size: 11)
    private let next = ChromeButton(symbol: "chevron.down", tip: L("find.next"), size: 11)
    private let closeButton = ChromeButton(symbol: "xmark", tip: L("find.close"), size: 10)

    var isOpen: Bool { superview != nil }

    private static let size = NSSize(width: 360, height: 42)

    init(controller: BrowserWindowController) {
        self.controller = controller
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -4)

        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1
        addSubview(card)

        glass.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        glass.contentTintColor = .secondaryLabelColor
        glass.imageScaling = .scaleNone

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = L("find.placeholder")
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false

        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        count.textColor = .secondaryLabelColor
        count.alignment = .right

        previous.target = self
        previous.action = #selector(findPrevious)
        next.target = self
        next.action = #selector(findNext)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        [glass, field, count, previous, next, closeButton].forEach(card.addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        card.layer?.backgroundColor = Theme.panel.cgColor
        card.layer?.borderColor = Theme.hairline.cgColor
    }

    func open(in content: NSView, tab: ArdiaCoreTab) {
        if self.tab !== tab { close() }
        self.tab = tab
        if superview !== content { content.addSubview(self) }
        place()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        if !field.stringValue.isEmpty { find(forward: true) }
    }

    func place() {
        guard let superview else { return }
        frame = NSRect(x: superview.bounds.width - Self.size.width - 14, y: superview.bounds.height - Self.size.height - 14,
                       width: Self.size.width, height: Self.size.height)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
        card.frame = bounds
        let h = bounds.height
        glass.frame = NSRect(x: 12, y: 0, width: 16, height: h)
        closeButton.frame = NSRect(x: bounds.width - 32, y: (h - 24) / 2, width: 24, height: 24)
        next.frame = NSRect(x: closeButton.frame.minX - 28, y: (h - 24) / 2, width: 24, height: 24)
        previous.frame = NSRect(x: next.frame.minX - 26, y: (h - 24) / 2, width: 24, height: 24)
        count.frame = NSRect(x: previous.frame.minX - 62, y: (h - 16) / 2, width: 56, height: 16)
        field.frame = NSRect(x: 34, y: (h - 18) / 2, width: count.frame.minX - 40, height: 18)
    }

    func close() {
        guard isOpen else { return }
        tab?.stopFinding()
        removeFromSuperview()
        count.stringValue = ""
        tab?.focus()
    }

    func update(count total: Int, active: Int) {
        count.stringValue = field.stringValue.isEmpty ? "" : total == 0 ? L("find.none") : "\(active)/\(total)"
        count.textColor = total == 0 && !field.stringValue.isEmpty ? .systemRed : .secondaryLabelColor
    }

    private func find(forward: Bool) {
        guard let tab else { return }
        if field.stringValue.isEmpty {
            tab.stopFinding()
            count.stringValue = ""
        } else {
            tab.find(field.stringValue, forward: forward)
        }
    }

    @objc private func findPrevious() { find(forward: false) }
    @objc private func findNext() { find(forward: true) }
    @objc private func closeTapped() { close() }

    func controlTextDidChange(_ obj: Notification) { find(forward: true) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            find(forward: !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        default:
            return false
        }
        return true
    }
}
