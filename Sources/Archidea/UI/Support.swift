import AppKit
import ArchideaCore

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
    /// Lines come from the main thread and from background work (an import, the password managers' check) at once;
    /// the list, the formatter and the file are only touched under this.
    private static let lock = NSLock()

    /// Lines are about what the app did, never what was browsed: no page titles, no addresses (`site(_:)` keeps
    /// only the scheme), since a saved log ends up attached to public issues.
    static func log(_ message: @autoclosure () -> String) {
        let text = message()
        lock.lock()
        defer { lock.unlock() }
        let line = "\(stamp.string(from: Date())) \(text)"
        recent.append(line)
        if recent.count > capacity { recent.removeFirst(recent.count - capacity) }
        guard enabled else { return }
        let output = Data("[trace] \(line)\n".utf8)
        FileHandle.standardError.write(output)
        file?.write(output)
    }

    /// An address as the log may show it: its kind, not where it goes.
    static func site(_ url: String) -> String {
        guard !url.isEmpty else { return "nothing" }
        guard let scheme = URL(string: url)?.scheme else { return "an address" }
        return "\(scheme): page"
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
        lock.lock()
        let lines = recent
        lock.unlock()
        guard (try? (header + lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return url
    }
}

extension SpaceStyle {
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

