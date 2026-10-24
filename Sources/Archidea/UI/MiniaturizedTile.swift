import AppKit

/// A picture of one of our own windows, as the Dock would show it minimised. CGWindowListCreateImage needs no
/// screen recording permission for the app's own windows, where ScreenCaptureKit's replacement may ask for it;
/// it's looked up at run time because the SDK marks it deprecated, and Swift can't silence that per call.
enum WindowPicture {
    private typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let create: Create? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")
        .map { unsafeBitCast($0, to: Create.self) }

    static func take(_ window: NSWindow) -> CGImage? {
        let options: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
        return create?(.null, CGWindowListOption.optionIncludingWindow.rawValue, CGWindowID(window.windowNumber), options.rawValue)?
            .takeRetainedValue()
    }
}

/// A minimised window in the Dock: its picture, scaled to fit, with the app's chosen icon in the corner.
final class MiniaturizedTile: NSView {
    var snapshot: NSImage?
    var badge: NSImage? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        if let snapshot, snapshot.size.width > 0 {
            let scale = min(bounds.width / snapshot.size.width, bounds.height / snapshot.size.height)
            let size = NSSize(width: snapshot.size.width * scale, height: snapshot.size.height * scale)
            snapshot.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
        }
        let side = bounds.width * 0.42
        badge?.draw(in: NSRect(x: bounds.maxX - side, y: 0, width: side, height: side))
    }
}
