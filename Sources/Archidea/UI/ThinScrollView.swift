import AppKit

/// Scrolling as the sidebar wants it everywhere: an overlay bar that shows while scrolling and fades, a thin knob
/// with no track that widens under the pointer — also when macOS is set to always show scroll bars (or a mouse
/// is plugged in), which otherwise brings back the wide legacy bar with its track.
/// A view that shows when the pointer is on it. A scroll view (`ThinScrollView`) asks it again as it scrolls.
protocol HoverTracking: NSView {
    var isHovered: Bool { get }
    /// Hover from where the pointer is now.
    func refreshHover()
}

class ThinScrollView: NSScrollView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = true
        hasHorizontalScroller = false
        verticalScroller = ThinScroller()
        autohidesScrollers = true
        horizontalScrollElasticity = .none
        super.scrollerStyle = .overlay
    }

    required init?(coder: NSCoder) { fatalError() }

    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }

    // MARK: edge fades

    /// Rows fade out at an edge that has more content beyond it, instead of being cut off by a hard line.
    var fadesEdges = false {
        didSet {
            guard fadesEdges != oldValue else { return }
            wantsLayer = true
            contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(updateFades), name: NSView.boundsDidChangeNotification,
                                                   object: contentView)
            updateFades()
        }
    }

    private let fade = CAGradientLayer()
    private let fadeLength: CGFloat = 18

    override func layout() {
        super.layout()
        updateFades()
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        updateFades()
        refreshHovers()
    }

    /// Hover follows the pointer through a scroll: what shows hover, and what's under the pointer now, ask again.
    /// Content moving under a still pointer gets no mouseEntered or mouseExited, so a row scrolled away kept its hover.
    func refreshHovers() {
        guard let document = documentView, let window, window.isVisible else { return }
        let point = document.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        func visit(_ view: NSView) {
            for child in view.subviews where !child.isHidden {
                if let tracking = child as? HoverTracking,
                   tracking.isHovered || child.convert(child.bounds, to: document).contains(point) {
                    tracking.refreshHover()
                }
                visit(child)
            }
        }
        visit(document)
    }

    @objc private func updateFades() {
        guard fadesEdges, let layer, bounds.height > fadeLength * 2 else { return }
        let visible = contentView.bounds
        let total = documentView?.frame.height ?? 0
        let flipped = documentView?.isFlipped ?? true
        let above = flipped ? visible.minY > 0.5 : visible.maxY < total - 0.5
        let below = flipped ? visible.maxY < total - 0.5 : visible.minY > 0.5
        let edge = NSNumber(value: Double(fadeLength / bounds.height))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = layer.bounds
        // The layer's y runs up the screen here: the first stop is the bottom edge.
        let clear = NSColor.clear.cgColor, solid = NSColor.black.cgColor
        fade.colors = [below ? clear : solid, solid, solid, above ? clear : solid]
        fade.locations = [0, edge, NSNumber(value: 1 - edge.doubleValue), 1]
        fade.startPoint = CGPoint(x: 0.5, y: layer.isGeometryFlipped ? 1 : 0)
        fade.endPoint = CGPoint(x: 0.5, y: layer.isGeometryFlipped ? 0 : 1)
        if layer.mask !== fade { layer.mask = fade }
        CATransaction.commit()
    }
}

final class ThinScroller: NSScroller {
    private var hovering = false { didSet { needsDisplay = true } }

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard knob.height > 0 else { return }
        let width: CGFloat = hovering ? 7 : 5
        let shape = NSRect(x: bounds.maxX - width - 3, y: knob.minY + 3, width: width, height: max(knob.height - 6, width * 2))
        NSColor.labelColor.withAlphaComponent(hovering ? 0.45 : 0.28).setFill()
        NSBezierPath(roundedRect: shape, xRadius: width / 2, yRadius: width / 2).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        hovering = isUnderPointer
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hovering = false
    }
}

/// Overlay scroll bars in web pages too. The engine asks `NSScroller.preferredScrollerStyle` which bars to give
/// pages, and macOS answers "legacy" whenever it's set to always show scroll bars or a mouse is plugged in, which
/// puts a wide grey track beside every page. Answering "overlay" gives pages Chromium's thin, fading bars.
/// Installed before the engine starts, since it reads the style once and then on the change notification.
enum OverlayScrollbars {
    static func install() {
        guard let method = class_getClassMethod(NSScroller.self, #selector(getter: NSScroller.preferredScrollerStyle)) else { return }
        let overlay: @convention(block) (AnyObject) -> NSScroller.Style = { _ in .overlay }
        method_setImplementation(method, imp_implementationWithBlock(overlay))
    }
}
