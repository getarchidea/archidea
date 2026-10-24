import AppKit
import ArchideaCore

/// Images for folder and space icons (`Glyph`): an SF Symbol as an outline or filled, or an emoji drawn as text.
/// Everything that shows such an icon goes through here, so a symbol and an emoji look alike everywhere.
enum Glyphs {
    /// Nil when `value` is neither an emoji nor a symbol this Mac has.
    static func image(_ value: String, filled: Bool, pointSize: CGFloat, weight: NSFont.Weight = .medium) -> NSImage? {
        if Glyph.isEmoji(value) { return emoji(value, pointSize: pointSize) }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        // A symbol without a filled form (or without an outline one) draws the form it has.
        for name in [Glyph.symbolName(value, filled: filled), Glyph.symbolName(value, filled: !filled)] {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
                return image.withSymbolConfiguration(configuration) ?? image
            }
        }
        return nil
    }

    /// Whether `value` draws: an emoji, or a symbol this Mac's SF Symbols has.
    static func exists(_ value: String) -> Bool {
        Glyph.isEmoji(value) || NSImage(systemSymbolName: value, accessibilityDescription: nil) != nil
    }

    /// An emoji as a picture about as tall as a symbol of the same point size. It keeps its own colours: it's no
    /// template, so a view's tint leaves it alone.
    private static func emoji(_ value: String, pointSize: CGFloat) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: pointSize * 0.95)]
        let text = value as NSString
        let size = text.size(withAttributes: attributes)
        let side = ceil(max(size.width, size.height))
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            text.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2), withAttributes: attributes)
            return true
        }
        image.isTemplate = false
        return image
    }
}
