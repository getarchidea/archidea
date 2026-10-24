import AppKit
import ArchideaCore

/// What a window shows for a tab whose page is in front in another window: a page is open in one window at a time.
/// The person can go to that window, or bring the page here.
final class ElsewherePage: NSView {
    var onShowWindow: (() -> Void)?
    var onMoveHere: (() -> Void)?

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: L("elsewhere.title"))
    private lazy var showButton = NSButton(title: L("elsewhere.show"), target: self, action: #selector(showTapped))
    private lazy var moveButton = NSButton(title: L("elsewhere.move"), target: self, action: #selector(moveTapped))

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.alignment = .center
        title.lineBreakMode = .byTruncatingTail
        note.font = .systemFont(ofSize: 13)
        note.textColor = .tertiaryLabelColor
        note.alignment = .center
        for button in [showButton, moveButton] { button.bezelStyle = .rounded }
        for view in [icon, title, note, showButton, moveButton] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func show(_ item: SidebarItem, icon image: NSImage?) {
        icon.image = image ?? NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: nil)
        icon.contentTintColor = image == nil ? .tertiaryLabelColor : nil
        title.stringValue = item.displayTitle
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = min(420, bounds.width - 64)
        var y = max(48, bounds.height * 0.36 - 80)
        icon.frame = NSRect(x: (bounds.width - 32) / 2, y: y, width: 32, height: 32)
        y += 32 + 16
        title.frame = NSRect(x: (bounds.width - width) / 2, y: y, width: width, height: 20)
        y += 20 + 6
        note.frame = NSRect(x: (bounds.width - width) / 2, y: y, width: width, height: 18)
        y += 18 + 20
        showButton.sizeToFit()
        moveButton.sizeToFit()
        let gap: CGFloat = 12
        var x = (bounds.width - showButton.frame.width - gap - moveButton.frame.width) / 2
        showButton.setFrameOrigin(NSPoint(x: x, y: y))
        x += showButton.frame.width + gap
        moveButton.setFrameOrigin(NSPoint(x: x, y: y))
    }

    @objc private func showTapped() { onShowWindow?() }
    @objc private func moveTapped() { onMoveHere?() }
}
