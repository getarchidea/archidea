import AppKit

/// The page is loading: a short capsule in the window's frame above the page, Arc-style — a dim track with a
/// light segment sliding back and forth along it — that fades out once the page is done. Its colours follow the
/// frame's light or dark look.
final class LoadingBar: NSView {
    static let size = NSSize(width: 140, height: 4)
    private let track = CALayer()
    private let glow = CALayer()
    private var visible = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        track.cornerRadius = Self.size.height / 2
        track.masksToBounds = true
        glow.cornerRadius = Self.size.height / 2
        track.addSublayer(glow)
        layer?.addSublayer(track)
        alphaValue = 0
        recolor()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolor()
    }

    private func recolor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.backgroundColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
            glow.backgroundColor = NSColor.labelColor.withAlphaComponent(0.55).cgColor
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        glow.frame = NSRect(x: 0, y: 0, width: bounds.width * 0.4, height: bounds.height)
        CATransaction.commit()
    }

    func show(loading: Bool, progress: Double, animated: Bool = true) {
        superview?.addSubview(self, positioned: .above, relativeTo: nil)
        guard loading != visible else { return }
        visible = loading
        if loading {
            recolor()
            needsLayout = true
            layoutSubtreeIfNeeded()
            let slide = CABasicAnimation(keyPath: "position.x")
            slide.fromValue = -Self.size.width * 0.2
            slide.toValue = Self.size.width * 1.2
            slide.duration = 0.9
            slide.autoreverses = true
            slide.repeatCount = .infinity
            slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glow.add(slide, forKey: "slide")
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animated ? (loading ? 0.15 : 0.35) : 0
            animator().alphaValue = loading ? 1 : 0
        }, completionHandler: { [weak self] in
            if self?.visible == false { self?.glow.removeAnimation(forKey: "slide") }
        })
    }
}
