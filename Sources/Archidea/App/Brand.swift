import AppKit

/// The app's icon: one of the designer's logos (Resources/Logos, made into icons by scripts/make-icons.swift),
/// chosen in Settings or on first launch. It shows in the Dock while the app runs. It isn't written onto the
/// bundle (a custom Finder icon): that adds a file the code signature doesn't cover and breaks it.
enum IconChoice {
    static let ids = ["dark-amethyst", "dark-iris", "dark-jade", "dark-yellow", "dark-terracotta", "light-amethyst", "light-iris", "light-jade", "light-yellow", "light-terracotta"]
    private static let key = "AppIcon"

    static var current: String {
        let id = UserDefaults.standard.string(forKey: key) ?? ids[0]
        return ids.contains(id) ? id : ids[0]
    }

    static func image(_ id: String) -> NSImage? {
        Bundle.main.url(forResource: id, withExtension: "icns", subdirectory: "Icons").flatMap(NSImage.init(contentsOf:))
    }

    static func preview(_ id: String) -> NSImage? {
        Bundle.main.url(forResource: id, withExtension: "png", subdirectory: "Icons").flatMap(NSImage.init(contentsOf:))
    }

    /// At launch: the engine has set Chromium's own icon by now. Also takes off a custom bundle icon that an
    /// earlier build set, so the signature is whole again.
    static func apply() {
        if let image = image(current) { NSApp.applicationIconImage = image }
        if FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Icon\r").path) {
            NSWorkspace.shared.setIcon(nil, forFile: Bundle.main.bundlePath, options: [])
        }
    }

    private static let changed = Notification.Name("IconChoiceChanged")

    /// Runs after the user picks another icon (minimised windows redraw their tile).
    @discardableResult
    static func onChange(_ handler: @escaping () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: changed, object: nil, queue: .main) { _ in handler() }
    }

    static func choose(_ id: String) {
        UserDefaults.standard.set(id, forKey: key)
        UserDefaults.standard.synchronize()
        if let image = image(id) { NSApp.applicationIconImage = image }
        NotificationCenter.default.post(name: changed, object: nil)
        // The Dock's plug-in (Sources/DockTile) redraws the tile it shows while the app isn't running.
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("app.archidea.browser.IconChanged"),
                                                                     object: nil, deliverImmediately: true)
    }
}

/// Moves what the app kept under its working name, Drift, to where Archidea keeps it: the data folder and
/// the few preferences. Runs once, before the engine starts; a still running old build is asked to quit first,
/// since its engine holds the profile open.
enum LegacyData {
    private static let oldBundleID = "dev.drift.browser"

    static func migrate(into root: URL) {
        let fm = FileManager.default
        let old = root.deletingLastPathComponent().appendingPathComponent("Drift", isDirectory: true)
        if !fm.fileExists(atPath: root.path), fm.fileExists(atPath: old.path) {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: oldBundleID) {
                app.terminate()
                let deadline = Date().addingTimeInterval(15)
                while !app.isTerminated, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
            }
            try? fm.moveItem(at: old, to: root)
        }
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "MigratedFromDrift"), let previous = UserDefaults(suiteName: oldBundleID) {
            for key in ["DriftLanguage", "DriftTrace"] where defaults.object(forKey: key) == nil {
                if let value = previous.object(forKey: key) { defaults.set(value, forKey: key) }
            }
            defaults.set(true, forKey: "MigratedFromDrift")
        }
    }
}
