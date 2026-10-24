import ArdiaCore
import Foundation

/// The optional built-in blocker: uBlock Origin, bundled in the app and loaded as a component extension.
/// Its ID comes from the key in its manifest; the engine keeps that extension away from
/// the Web Store and chrome:// pages.
enum AdBlocker {
    static let extensionID = "fajbdaomknpkicfjcpipdmcpoamdmilh"
    private static var loaded = false

    private static var bundledPath: String? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Extensions/ublock"),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) else { return nil }
        return url.path
    }

    static var isAvailable: Bool { bundledPath != nil }

    static func apply(_ enabled: Bool, to profile: ArdiaCoreProfile) {
        if enabled, !loaded, let path = bundledPath {
            let id = profile.loadComponentExtension(path)
            loaded = id != nil
            Trace.log("ad blocker: loaded \(id ?? "nothing") from \(path)")
        } else if !enabled, loaded {
            profile.unloadComponentExtension(extensionID)
            loaded = false
            Trace.log("ad blocker: unloaded")
        }
    }
}
