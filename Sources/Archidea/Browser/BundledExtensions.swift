import ArdiaCore
import Foundation

/// Extensions that ship inside the app, each switched on and off by a setting and loaded as a component extension.
/// Each one's ID comes from the key its scripts/fetch-*.sh puts in its manifest; the engine keeps uBlock Origin's away
/// from the Web Store and chrome:// pages.
struct BundledExtension: Hashable {
    let id: String
    /// Its folder in Contents/Resources/Extensions.
    let folder: String

    /// The built-in ad and tracker blocker: uBlock Origin (scripts/fetch-ublock.sh).
    static let adBlocker = BundledExtension(id: "fajbdaomknpkicfjcpipdmcpoamdmilh", folder: "ublock")
    /// Cookie banners answered with "reject all", or hidden: DuckDuckGo's autoconsent (scripts/fetch-autoconsent.sh).
    static let cookieBanners = BundledExtension(id: "iiefeinnpgnnjpnjpdaaeaefcpnbedal", folder: "autoconsent")

    static let all: [BundledExtension] = [.adBlocker, .cookieBanners]
    static let ids = Set(all.map(\.id))

    private static var loaded: Set<String> = []

    private var bundledPath: String? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Extensions/\(folder)"),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) else { return nil }
        return url.path
    }

    var isAvailable: Bool { bundledPath != nil }

    /// Loads or unloads it in `profile` (the normal one: private windows share its component extensions).
    func apply(_ enabled: Bool, to profile: ArdiaCoreProfile) {
        let isLoaded = Self.loaded.contains(id)
        if enabled, !isLoaded, let path = bundledPath {
            let loadedID = profile.loadComponentExtension(path)
            if loadedID != nil { Self.loaded.insert(id) }
            Trace.log("\(folder): loaded \(loadedID ?? "nothing")")
        } else if !enabled, isLoaded {
            profile.unloadComponentExtension(id)
            Self.loaded.remove(id)
            Trace.log("\(folder): unloaded")
        }
    }
}
