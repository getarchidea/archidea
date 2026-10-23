import AppKit

/// Traffic lights inset into the sidebar, Arc-style. AppKit re-lays them out on every resize,
/// so the frame view's private `_closeButtonOrigin` answers with our position instead.
enum TrafficLights {
    static let inset = NSPoint(x: 18, y: 18)
    static let identifier = NSUserInterfaceItemIdentifier("drift.main")

    static var centerY: CGFloat { inset.y + 7 }

    static func install(on window: NSWindow) {
        window.identifier = identifier
        guard let frameView = window.contentView?.superview, let cls = object_getClass(frameView) else { return }
        let selector = NSSelectorFromString("_closeButtonOrigin")
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        typealias Origin = @convention(c) (AnyObject, Selector) -> NSPoint
        let standard = unsafeBitCast(method_getImplementation(method), to: Origin.self)
        let ours: @convention(block) (NSView) -> NSPoint = { view in
            guard let window = view.window, window.identifier == identifier, !window.styleMask.contains(.fullScreen) else {
                return standard(view, selector)
            }
            let size = window.standardWindowButton(.closeButton)?.frame.size ?? NSSize(width: 14, height: 14)
            return NSPoint(x: inset.x, y: view.bounds.height - inset.y - size.height)
        }
        let imp = imp_implementationWithBlock(ours)
        if !class_addMethod(cls, selector, imp, method_getTypeEncoding(method)) { method_setImplementation(method, imp) }
        retile(window)
    }

    static func retile(_ window: NSWindow) {
        let selector = NSSelectorFromString("_updateButtonPositions")
        if let frameView = window.contentView?.superview, frameView.responds(to: selector) {
            frameView.perform(selector)
        }
    }

    static func setVisible(_ visible: Bool, in window: NSWindow, animated: Bool = true) {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
        for button in buttons {
            if visible { button.isHidden = false }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = animated ? 0.15 : 0
                button.animator().alphaValue = visible ? 1 : 0
            }, completionHandler: {
                if !visible, button.alphaValue == 0 { button.isHidden = true }
            })
        }
    }
}

extension NSView {
    /// The pointer is over this view and nothing covers it: no other window (a popover, a menu) and no other
    /// view in this window (the command bar, an extension popup). Tracking areas fire whatever is on top,
    /// so hover and cursor changes check this first.
    var isUnderPointer: Bool {
        guard let window, window.isVisible else { return false }
        guard NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window.windowNumber else { return false }
        let point = window.mouseLocationOutsideOfEventStream
        guard bounds.contains(convert(point, from: nil)), let hit = window.contentView?.superview?.hitTest(point) else { return false }
        return hit === self || hit.isDescendant(of: self) || isDescendant(of: hit)
    }
}

/// Marks views whose empty space moves the window.
protocol WindowDragSurface: NSView {}

enum WindowDrag {
    /// Chrome's content view swallows presses before most of our views see them, so the window
    /// controller asks this from a local mouse-down monitor and performs the drag itself.
    static func isDragSurface(_ hit: NSView?, at point: NSPoint) -> Bool {
        guard let hit else { return false }
        if hit is WindowDragSurface { return true }
        if let outline = hit as? NSOutlineView {
            return outline.row(at: outline.convert(point, from: nil)) < 0
        }
        if hit is NSClipView, (hit.superview as? NSScrollView)?.documentView is NSOutlineView { return true }
        let name = NSStringFromClass(type(of: hit))
        return name.contains("Titlebar") || name.hasPrefix("NSThemeFrame")
    }

    /// What a press at `point` (window coordinates) would hit, and whether it moves the window.
    static func probe(_ point: NSPoint, in window: NSWindow) -> String {
        let hit = window.contentView?.superview?.hitTest(point)
        var chain: [String] = []
        var view = hit
        while let v = view, chain.count < 7 {
            chain.append(NSStringFromClass(type(of: v)).replacingOccurrences(of: "Drift.", with: ""))
            view = v.superview
        }
        return "\(isDragSurface(hit, at: point) ? "DRAG" : "----") \(chain.joined(separator: " < "))"
    }

    static func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.window === window, !event.modifierFlags.contains(.control),
              !window.styleMask.contains(.fullScreen),
              isDragSurface(window.contentView?.superview?.hitTest(event.locationInWindow), at: event.locationInWindow) else { return false }
        Trace.log("window drag took a press on \(probe(event.locationInWindow, in: window))")
        if event.clickCount == 2 {
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            if action == "Minimize" { window.performMiniaturize(nil) } else if action != "None" { window.performZoom(nil) }
        } else {
            window.performDrag(with: event)
        }
        return true
    }
}
