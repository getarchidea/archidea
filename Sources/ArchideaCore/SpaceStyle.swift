import Foundation

/// The colours and icons spaces and folders are given. An icon is an SF Symbol's name or an emoji (`Glyph`).
public enum SpaceStyle {
    public static let palette = ["#7C8CF8", "#F28C6B", "#5EC48B", "#E06BB5", "#F2C14E", "#4FB3D9", "#A07CF8", "#8A8F98"]
    public static var names: [String] { ["indigo", "coral", "mint", "pink", "sun", "sky", "lavender", "graphite"].map { L("color.\($0)") } }
    /// What new spaces get in turn.
    public static let symbols = ["house", "briefcase", "book", "gamecontroller", "music.note", "paintbrush", "leaf", "star",
                                 "heart", "bolt", "cart", "graduationcap", "airplane", "camera", "flame", "moon"]

    /// The icon picker's symbols, grouped loosely by theme. Each is drawn as an outline or filled (`Glyph.symbolName`);
    /// one this Mac's SF Symbols lacks is left out of the picker.
    public static let pickerSymbols = [
        // Everyday
        "folder", "house", "star", "heart", "bolt", "flame", "sparkles", "bookmark", "flag", "tag", "bell", "pin",
        "mappin", "lightbulb", "crown", "seal", "shield", "lock", "key", "gift", "trophy", "medal", "hand.thumbsup",
        "face.smiling",
        // Work
        "briefcase", "doc", "doc.text", "tray", "archivebox", "calendar", "clock", "chart.bar", "chart.pie",
        "list.bullet.clipboard", "envelope", "paperplane", "bubble.left", "bubble.left.and.bubble.right", "phone", "person",
        "person.2", "building.2", "banknote", "creditcard", "cart", "bag", "signature", "pencil.and.outline",
        // Making
        "hammer", "wrench.and.screwdriver", "gearshape", "terminal", "keyboard", "cpu", "externaldrive", "cloud",
        "server.rack", "network", "link", "ant", "ladybug", "cube", "shippingbox", "puzzlepiece", "paintbrush",
        "paintpalette", "pencil.tip", "scissors", "ruler", "camera", "photo", "film", "video", "mic", "music.note",
        "headphones", "play", "tv", "gamecontroller", "dice",
        // Learning
        "book", "books.vertical", "book.closed", "newspaper", "magazine", "graduationcap", "backpack", "studentdesk",
        "brain.head.profile", "atom", "flask", "testtube.2", "function", "globe.europe.africa", "map", "binoculars",
        // Life
        "leaf", "tree", "camera.macro", "sun.max", "moon", "moon.stars", "cloud.sun", "snowflake", "drop", "pawprint",
        "fish", "bird", "tortoise", "hare", "carrot", "fork.knife", "cup.and.saucer", "wineglass", "birthday.cake",
        "basket", "dumbbell", "figure.run", "figure.mind.and.body", "heart.text.square", "cross.case", "pills",
        "bed.double", "sofa", "lamp.desk",
        // Going places
        "car", "bus", "tram", "bicycle", "airplane", "ferry", "sailboat", "suitcase", "tent", "mountain.2",
        "beach.umbrella", "globe.americas", "location", "safari",
    ]

    /// The emoji the picker offers first; any other can be typed in or picked from the Character Viewer.
    public static let pickerEmoji = [
        "🏠", "💼", "📚", "🎮", "🎵", "🎨", "🌿", "⭐️", "❤️", "⚡️", "🔥", "✨",
        "🚀", "🧠", "💡", "📌", "📁", "🗂️", "🗓️", "📈", "💰", "🛒", "✈️", "🌍",
        "🏖️", "⛰️", "🍕", "☕️", "🍷", "🎂", "🐶", "🐱", "🦊", "🐼", "🌸", "🌈",
        "☀️", "🌙", "❄️", "💻", "🛠️", "🧪", "📷", "🎬", "📺", "🎧", "📰", "🎓",
        "🏋️", "⚽️", "🚗", "🚲", "🏢", "💊", "🧘", "🤖", "👾", "🎯", "🏆", "🎁",
        "🔒", "🔑", "🧩", "📝", "✅", "💬", "📧", "🌐", "🗺️", "🧳", "⏰", "🛍️",
        "🍔", "🥗", "🍎", "🍜", "🍺", "🎉", "👀", "👋", "🙂", "😎", "🤓", "💜",
    ]

    public static func colorName(_ hex: String) -> String {
        palette.firstIndex(of: hex).map { names[$0] } ?? hex
    }
}

/// An icon as folders and spaces keep it: an SF Symbol's name, or an emoji.
public enum Glyph {
    /// Whether `value` is an emoji (drawn as text) rather than a symbol's name. One grapheme that shows as emoji:
    /// emoji by default (🏠), or made so by a variation selector or a sequence (❤️, 👨‍💻).
    public static func isEmoji(_ value: String) -> Bool {
        guard value.count == 1, let first = value.unicodeScalars.first else { return false }
        return first.properties.isEmojiPresentation || (first.properties.isEmoji && value.unicodeScalars.count > 1)
    }

    /// The symbol to draw for `value`, as an outline or filled: "star" and "star.fill" are the same icon. Other
    /// names (an emoji, a symbol with no filled form) are the caller's to fall back from.
    public static func symbolName(_ value: String, filled: Bool) -> String {
        let base = value.hasSuffix(".fill") ? String(value.dropLast(".fill".count)) : value
        return filled ? "\(base).fill" : base
    }
}
