import AppKit

enum Theme {
    static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }

    static let tintAlpha: CGFloat = 0.22
    static let selectedCard = dynamic(dark: .white.withAlphaComponent(0.13), light: .white.withAlphaComponent(0.85))
    static let hover = dynamic(dark: .white.withAlphaComponent(0.07), light: .black.withAlphaComponent(0.05))
    static let addressFill = dynamic(dark: .white.withAlphaComponent(0.07), light: .white.withAlphaComponent(0.5))
    static let addressHover = dynamic(dark: .white.withAlphaComponent(0.11), light: .white.withAlphaComponent(0.7))
    static let hairline = dynamic(dark: .white.withAlphaComponent(0.08), light: .black.withAlphaComponent(0.08))
    static let page = dynamic(dark: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1), light: .white)
    static let panel = dynamic(dark: NSColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 0.98),
                               light: NSColor(srgbRed: 0.99, green: 0.99, blue: 1, alpha: 0.98))
    /// Approximate luminance of the sidebar: the window's vibrant base with the space colour laid over it.
    static func sidebarLuminance(dark: Bool, tint: NSColor, strength: CGFloat) -> CGFloat {
        let c = tint.usingColorSpace(.sRGB) ?? tint
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let tintLuminance = 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
        let base: CGFloat = dark ? 0.03 : 0.8
        let mixed = base * (1 - strength) + tintLuminance * strength
        return pow(mixed, 1 / 2.2)
    }

    static let settingsCard = dynamic(dark: .white.withAlphaComponent(0.05), light: .white.withAlphaComponent(0.7))
    /// The start page's search field, on the page's own colour.
    static let startField = dynamic(dark: .white.withAlphaComponent(0.06), light: .black.withAlphaComponent(0.035))
    static let keycap = dynamic(dark: .white.withAlphaComponent(0.08), light: .black.withAlphaComponent(0.05))
}

/// Diagnostics: why tabs activate, where presses go, what's key after switching apps.
/// On with DRIFT_TRACE=1 (stderr), or `defaults write dev.drift.browser DriftTrace -bool YES`
/// (appended to trace.log in the data folder), so it can be turned on for a normal launch too.
/// What the app did, for bug reports. The last couple of thousand lines are always kept in memory, so when
/// something goes wrong Help › Save Diagnostic Log writes them out without a restart. With DriftTrace on (or
/// DRIFT_TRACE=1) every line also goes to stderr and to <data>/trace.log as it happens.
enum Trace {
    static let enabled = ProcessInfo.processInfo.environment["DRIFT_TRACE"] == "1" || UserDefaults.standard.bool(forKey: "DriftTrace")
    private static let capacity = 2000
    private static var recent: [String] = []
    private static let file: FileHandle? = {
        guard UserDefaults.standard.bool(forKey: "DriftTrace") else { return nil }
        let url = Paths.root.appendingPathComponent("trace.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }()
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func log(_ message: @autoclosure () -> String) {
        let line = "\(stamp.string(from: Date())) \(message())"
        recent.append(line)
        if recent.count > capacity { recent.removeFirst(recent.count - capacity) }
        guard enabled else { return }
        let text = "[trace] \(line)\n"
        FileHandle.standardError.write(text.data(using: .utf8)!)
        file?.write(text.data(using: .utf8)!)
    }

    /// Writes what's been kept to ~/Library/Logs/Archidea and returns the file.
    static func save() -> URL? {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Archidea")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = DateFormatter()
        name.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = folder.appendingPathComponent("archidea-\(name.string(from: Date())).log")
        let info = Bundle.main.infoDictionary
        let header = "Archidea \(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?")), "
            + "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        guard (try? (header + recent.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return url
    }
}

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

    static func swatch(_ hex: String) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(hex: hex).setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }
}

extension NSColor {
    convenience init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

enum URLInput {
    static var engine = SearchEngine.google
    static var searchTemplate: String { engine.template }

    static func resolve(_ raw: String) -> String {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty { return "about:blank" }
        let lower = input.lowercased()
        for scheme in ["http://", "https://", "file://", "about:", "chrome:", "chrome-extension:", "data:", "view-source:"] where lower.hasPrefix(scheme) {
            return input
        }
        if !input.contains(" ") {
            let host = lower.split(separator: "/").first.map(String.init) ?? lower
            let bare = host.split(separator: ":").first.map(String.init) ?? host
            if bare == "localhost" || bare.hasSuffix(".localhost") || isIPv4(bare) { return "http://\(input)" }
            if let tld = bare.split(separator: ".").last, bare.contains("."), tld.count >= 2, tld.allSatisfy(\.isLetter) {
                return "https://\(input)"
            }
        }
        let query = input.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? input
        return searchTemplate.replacingOccurrences(of: "%@", with: query)
    }

    static func isSearch(_ input: String) -> Bool {
        let prefix = searchTemplate.components(separatedBy: "%@")[0]
        return resolve(input).hasPrefix(prefix)
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }
}

extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?#")
        return set
    }()
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

enum Prompts {
    static func permissionName(_ kind: String) -> String {
        let key = "permission.\(kind)"
        let name = L(key)
        return name == key ? kind : name
    }
}

