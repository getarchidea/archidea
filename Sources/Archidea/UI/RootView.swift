import AppKit

/// Window content: blurred backdrop tinted by the space, sidebar on the left, the page card on the right.
/// A hidden sidebar slides back in over the page as a floating card while the pointer is at the left edge.
final class RootView: NSView, WindowDragSurface {
    enum SidebarMode { case docked, hidden, overlay }

    weak var sidebar: SidebarView?
    weak var content: ContentView?
    var sidebarWidth: Double = 260
    var mode: SidebarMode = .docked
    var contentFullscreen = false
    var onSidebarResize: ((Double) -> Void)?
    /// Dragging the docked sidebar past `collapseWidth` hides it; dragging back out in the same drag brings it back.
    var onCollapse: (() -> Void)?
    var onExpand: (() -> Void)?
    private(set) var isResizing = false
    private var widthBeforeDrag: Double = 260
    private var collapsedInDrag = false

    static let gap: CGFloat = 8
    /// The floating sidebar sits this far in from the window's edges.
    static let overlayInset: CGFloat = 5
    static let minWidth: Double = 200
    static let maxWidth: Double = 420
    static let collapseWidth: CGFloat = 120
    static let expandWidth: CGFloat = 160
    static let collapseDuration: TimeInterval = 0.38

    var tintStrength: CGFloat = Theme.tintAlpha
    var tint: NSColor? {
        didSet { tintView.layer?.backgroundColor = tint?.withAlphaComponent(tintStrength).cgColor }
    }

    private let backdrop = BackdropView()
    private let tintView = TintView()
    private let pageShadow = PageShadow()
    private let handle = ResizeHandle()

    override init(frame: NSRect) {
        super.init(frame: frame)
        backdrop.material = .sidebar
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        tintView.wantsLayer = true
        addSubview(backdrop)
        addSubview(tintView)
        addSubview(pageShadow)
        handle.onBegin = { [weak self] in
            guard let self else { return }
            isResizing = true
            collapsedInDrag = false
            widthBeforeDrag = max(Self.minWidth, sidebarWidth)
        }
        handle.onDrag = { [weak self] x in self?.resize(to: x) }
        handle.onEnd = { [weak self] in
            guard let self else { return }
            isResizing = false
            if sidebarWidth < Self.minWidth {
                sidebarWidth = Self.minWidth
                animateLayout(duration: 0.25)
            }
            onSidebarResize?(sidebarWidth)
            needsLayout = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func install(sidebar: SidebarView, content: ContentView) {
        self.sidebar = sidebar
        self.content = content
        addSubview(content)
        addSubview(sidebar)
        addSubview(handle)
    }

    /// Below the minimum the sidebar gives way slowly, like a rubber band; past `collapseWidth` it slides away,
    /// and pulling back out before letting go brings it back.
    private func resize(to x: CGFloat) {
        switch mode {
        case .docked:
            if x < Self.collapseWidth {
                collapsedInDrag = true
                sidebarWidth = widthBeforeDrag
                onCollapse?()
                return
            }
            let width = Double(x)
            sidebarWidth = width >= Self.minWidth
                ? min(Self.maxWidth, width)
                : Self.minWidth - (Self.minWidth - width) * 0.3
        case .overlay:
            sidebarWidth = min(Self.maxWidth, max(Self.minWidth, Double(x - Self.overlayInset)))
        case .hidden:
            if collapsedInDrag, x > Self.expandWidth {
                collapsedInDrag = false
                sidebarWidth = min(Self.maxWidth, max(Self.minWidth, Double(x)))
                onExpand?()
            }
            return
        }
        needsLayout = true
    }

    var sidebarFrame: NSRect {
        let width = CGFloat(sidebarWidth)
        switch mode {
        case .docked: return NSRect(x: 0, y: 0, width: width, height: bounds.height)
        // Flush with the window's edges, like Arc: it covers the window border instead of leaving a strip beside it.
        case .overlay:
            let inset = Self.overlayInset
            return NSRect(x: inset, y: inset, width: width, height: bounds.height - inset * 2)
        case .hidden: return NSRect(x: -width - 24, y: 0, width: width, height: bounds.height)
        }
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        tintView.frame = bounds
        let docked = mode == .docked && !contentFullscreen
        let gap = contentFullscreen ? 0 : Self.gap
        let left = docked ? CGFloat(sidebarWidth) : gap
        let page = NSRect(x: left, y: gap, width: max(0, bounds.width - left - gap), height: max(0, bounds.height - gap * 2))
        content?.frame = page
        content?.cornerRadius = contentFullscreen ? 0 : 10
        pageShadow.frame = page
        // A split's pages are cards of their own, each with its shadow.
        pageShadow.isHidden = contentFullscreen || content?.showsCard == false
        let side = contentFullscreen ? sidebarFrame.offsetBy(dx: -CGFloat(sidebarWidth) - 40, dy: 0) : sidebarFrame
        // The slid-out sidebar lies over the page: the page's corner cards keep clear of it, moving with it.
        content?.sidebarClearance = mode == .overlay && !contentFullscreen ? max(0, side.maxX - page.minX) : 0
        sidebar?.frame = side
        sidebar?.floating = mode != .docked
        handle.frame = NSRect(x: side.maxX - 6, y: side.minY, width: 12, height: side.height)
        handle.isHidden = !isResizing && (contentFullscreen || mode == .hidden)
    }

    func animateLayout(duration: TimeInterval = 0.22) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
            context.allowsImplicitAnimation = true
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }
}

/// The page card sits a little above the chrome: a soft shadow behind it, and behind each card of a split.
/// AppKit owns the layers of the views it manages and resets shadows set on them, so this one applies its own in `updateLayer`.
final class PageShadow: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.masksToBounds = false
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.16
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: -1)
        layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 10, cornerHeight: 10, transform: nil)
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class BackdropView: NSVisualEffectView, WindowDragSurface {}
private final class TintView: NSView, WindowDragSurface {}

final class ContentView: NSView {
    weak var emptyState: NSView?
    var onLayout: (() -> Void)?
    /// Whether the area is the page's card. A split's pages are cards of their own, with the window between them:
    /// then it's clear, and lets their shadows and the ring round the page with the keyboard show past its edges.
    var showsCard = true {
        didSet {
            guard showsCard != oldValue else { return }
            needsDisplay = true
            superview?.needsLayout = true
        }
    }
    /// The page with the keyboard: a split's one card, or all of it. The find bar and the site's prompts sit on it.
    var activeFrame: NSRect? {
        didSet { if activeFrame != oldValue { needsLayout = true } }
    }
    var pageFrame: NSRect { activeFrame ?? bounds }
    /// How much of the page's left edge the slid-out sidebar covers.
    var sidebarClearance: CGFloat = 0 {
        didSet { if sidebarClearance != oldValue { needsLayout = true } }
    }

    var cornerRadius: CGFloat = 10 {
        didSet { layer?.cornerRadius = cornerRadius }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        clipsToBounds = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.masksToBounds = showsCard
        layer?.backgroundColor = showsCard ? Theme.page.cgColor : NSColor.clear.cgColor
        layer?.borderColor = Theme.hairline.cgColor
        layer?.borderWidth = showsCard ? 1 : 0
    }

    override func layout() {
        super.layout()
        emptyState?.frame = bounds
        // The pages first: the find bar and prompts go on the one with the keyboard.
        onLayout?()
        for case let bar as FindBar in subviews { bar.place() }
        for case let card as PromptCard in subviews { card.place() }
    }
}

/// The sidebar's edge. The cursor is set from a tracking area rather than cursor rects, which only work in
/// the key window and stop after switching apps.
final class ResizeHandle: NSView {
    var onBegin: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    private var showsCursor = false

    private func updateCursor() {
        let on = isUnderPointer
        if on { NSCursor.resizeLeftRight.set() } else if showsCursor { NSCursor.arrow.set() }
        showsCursor = on
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor() }
    override func mouseEntered(with event: NSEvent) { updateCursor() }
    override func mouseMoved(with event: NSEvent) { updateCursor() }

    override func mouseExited(with event: NSEvent) {
        if showsCursor { NSCursor.arrow.set() }
        showsCursor = false
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
        onBegin?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        NSCursor.resizeLeftRight.set()
        onDrag?(superview.convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) { onEnd?() }
}

#if DRIFT_DEV
extension RootView {
    func debugResize(to x: CGFloat) { resize(to: x) }
    func debugBeginResize() { isResizing = true; collapsedInDrag = false; widthBeforeDrag = max(Self.minWidth, sidebarWidth) }
    func debugEndResize() { isResizing = false; if sidebarWidth < Self.minWidth { sidebarWidth = Self.minWidth }; needsLayout = true }
}
#endif
