import AppKit

/// Extension icons straight from their installed files: the manifest's `icons` (or its toolbar icon), the
/// largest size. The engine's chrome://extension-icon URLs don't answer outside a page, so tiles stayed blank.
enum ExtensionIcons {
    private static var cache: [String: NSImage] = [:]

    static func image(for id: String, path: String? = nil) -> NSImage? {
        if let cached = cache[id] { return cached }
        let fm = FileManager.default
        let folder: URL? = path.map { URL(fileURLWithPath: $0) } ?? {
            let base = Paths.chromium.appendingPathComponent("Default/Extensions/\(id)")
            let versions = (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
            return versions.filter { fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
                .max { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }
        }()
        guard let folder, let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let action = (manifest["action"] ?? manifest["browser_action"]) as? [String: Any]
        let candidates = [manifest["icons"] as? [String: String], action?["default_icon"] as? [String: String]].compactMap { $0 }
        for icons in candidates {
            guard let best = icons.max(by: { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) })?.value else { continue }
            let file = folder.appendingPathComponent(best.hasPrefix("/") ? String(best.dropFirst()) : best)
            if let image = NSImage(contentsOf: file) {
                cache[id] = image
                return image
            }
        }
        return nil
    }
}
