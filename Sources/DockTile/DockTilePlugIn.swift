import AppKit

/// Archidea's Dock icon while the app isn't running. macOS shows the bundle's own icon then, and writing another
/// icon into the bundle would break its signature, so the Dock asks this plug-in instead: it draws the look chosen
/// in Settings and redraws when the app says the choice changed.
@objc(ArchideaDockTilePlugIn)
final class ArchideaDockTilePlugIn: NSObject, NSDockTilePlugIn {
    private static let appID = "app.archidea.browser" as CFString
    static let changed = Notification.Name("app.archidea.browser.IconChanged")
    private var tile: NSDockTile?
    private var observer: NSObjectProtocol?

    func setDockTile(_ dockTile: NSDockTile?) {
        tile = dockTile
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        guard dockTile != nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: Self.changed, object: nil, queue: .main) { [weak self] _ in
            self?.draw()
        }
        draw()
    }

    private func draw() {
        guard let tile else { return }
        CFPreferencesAppSynchronize(Self.appID)
        let id = CFPreferencesCopyAppValue("AppIcon" as CFString, Self.appID) as? String ?? "dark-amethyst"
        let resources = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Icons")
        guard let image = NSImage(contentsOf: resources.appendingPathComponent("\(id).icns"))
            ?? NSImage(contentsOf: resources.appendingPathComponent("dark-amethyst.icns")) else { return }
        let view = NSImageView(frame: NSRect(origin: .zero, size: tile.size))
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        tile.contentView = view
        tile.display()
    }
}
