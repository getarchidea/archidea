import Foundation

/// The colours and symbols spaces and folders are given.
enum SpaceStyle {
    static let palette = ["#7C8CF8", "#F28C6B", "#5EC48B", "#E06BB5", "#F2C14E", "#4FB3D9", "#A07CF8", "#8A8F98"]
    static var names: [String] { ["indigo", "coral", "mint", "pink", "sun", "sky", "lavender", "graphite"].map { L("color.\($0)") } }
    static let symbols = ["house", "briefcase", "book", "gamecontroller", "music.note", "paintbrush", "leaf", "star",
                          "heart", "bolt", "cart", "graduationcap", "airplane", "camera", "flame", "moon"]

    static let folderSymbols = ["folder", "star", "heart", "bolt", "flame", "sparkles",
                                "briefcase", "hammer", "chart.bar", "doc.text", "newspaper", "book",
                                "graduationcap", "paintbrush", "music.note", "gamecontroller", "camera", "film",
                                "cart", "airplane", "leaf", "globe", "flag", "bookmark"]

    static func colorName(_ hex: String) -> String {
        palette.firstIndex(of: hex).map { names[$0] } ?? hex
    }
}
