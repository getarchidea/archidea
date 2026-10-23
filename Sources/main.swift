import Foundation

// Chromium owns the process: nothing may touch NSApp before the engine runs.
// The chosen Dock icon goes on as soon as the app finishes launching, before the engine's start-up work,
// so the standard icon doesn't flash in between. Observing doesn't touch NSApp.
NotificationCenter.default.addObserver(forName: NSApplication.willFinishLaunchingNotification, object: nil, queue: nil) { _ in
    IconChoice.apply()
}
exit(EngineHost.run())
