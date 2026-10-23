import AppKit

final class EngineHost: NSObject, ArdiaCoreEngineDelegate {
    static let shared = EngineHost()

    private(set) var app: AppDelegate?

    static func run() -> Int32 {
        Paths.prepare()
        OverlayScrollbars.install()
        let env = ProcessInfo.processInfo.environment
        var args: [String] = [
            CommandLine.arguments.first ?? "Archidea",
            "--user-data-dir=\(Paths.chromium.path)",
            "--profile-directory=Default",
            "--enable-smooth-scrolling",
            "--disable-stack-profiler",
            "--disable-features=MacAppCodeSignClone,DevToolsAcceptDebuggingConnections",
            "--enable-features=WebContentsDiscard,InfiniteTabsFreezing,ThrottleMainFrameTo60Hz,UrgentMainFrameForInput",
        ]
        if env["DRIFT_REAL_KEYCHAIN"] == nil { args.append("--use-mock-keychain") }
        L10n.configure()
        PasswordManagers.sync(into: Paths.chromium)
        args.append("--lang=\(L10n.code)")
        let languages = acceptLanguages()
        if !languages.isEmpty { args.append("--accept-lang=\(languages)") }
        // Dev passthrough: --remote-debugging-port=9222 and friends. Cocoa's "-Key value" defaults are skipped.
        var rest = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = rest.next() {
            if arg.hasPrefix("--") { args.append(arg) }
            else if arg.hasPrefix("-"), !arg.hasPrefix("-psn_") { _ = rest.next() }
        }

        let argv = args.map { UnsafePointer<CChar>(strdup($0)!) }
        let buffer = UnsafeMutablePointer<UnsafePointer<CChar>>.allocate(capacity: argv.count)
        buffer.initialize(from: argv, count: argv.count)
        return ArdiaCoreEngine.run(withArgc: Int32(argv.count), argv: buffer, delegate: shared)
    }

    private static func acceptLanguages() -> String {
        var list: [String] = []
        for identifier in Locale.preferredLanguages {
            let locale = Locale(identifier: identifier)
            guard let language = locale.language.languageCode?.identifier else { continue }
            if let region = locale.region?.identifier {
                let tag = "\(language)-\(region)"
                if !list.contains(tag) { list.append(tag) }
            }
            if !list.contains(language) { list.append(language) }
        }
        return list.joined(separator: ",")
    }

    // MARK: ArdiaCoreEngineDelegate

    @objc func engineDidStart() {
        let app = AppDelegate()
        self.app = app
        NSApp.delegate = app
        app.start()
    }

    @objc(engineQuitCancelled) func engineQuitCancelled() {
        Trace.log("engine: quit cancelled")
    }

    @objc(engineWillShutDown) func engineWillShutDown() {
        Trace.log("engine: will shut down")
        app?.store.saveNow()
        Updater.shared.installOnQuit()
    }

    @objc(engineWindowForNewBrowserOfProfile:type:)
    func engineWindowForNewBrowser(of profile: ArdiaCoreProfile, type: String) -> ArdiaCoreWindow? {
        guard type == "normal" || type == "popup" else { return nil }
        return app?.controller(for: profile)?.coreWindow
    }

    @objc(engine:permissionRequest:tab:)
    func engine(_ engine: ArdiaCoreEngine, permissionRequest request: [String: Any], tab: ArdiaCoreTab) {
        app?.controller(for: tab)?.showPermissionRequest(request, tab: tab)
    }

    @objc(engine:permissionRequestDismissed:)
    func engine(_ engine: ArdiaCoreEngine, permissionRequestDismissed requestId: String) {
        app?.windowController?.dismissPermissionRequest(requestId)
        app?.privateDismiss(requestId)
    }

    @objc(engine:extensionInstallPrompt:tab:)
    func engine(_ engine: ArdiaCoreEngine, extensionInstallPrompt prompt: [String: Any], tab: ArdiaCoreTab?) {
        guard let controller = app?.windowController else {
            ArdiaCoreEngine.resolveExtensionInstallPrompt(prompt["requestId"] as? String ?? "", accepted: false)
            return
        }
        controller.showExtensionInstallPrompt(prompt)
    }

    @objc(engine:extensionActionPopup:tab:)
    func engine(_ engine: ArdiaCoreEngine, extensionActionPopup popup: [String: Any], tab: ArdiaCoreTab) -> Bool {
        guard let controller = app?.windowController, let id = popup["extensionId"] as? String else { return false }
        controller.extensions.openPopup(extensionId: id, from: nil)
        return true
    }

    @objc(engineIsReservedKey:unshiftedKey:modifiers:)
    func engineIsReservedKey(_ key: String, unshiftedKey: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        Shortcuts.isReserved(key: key, unshiftedKey: unshiftedKey, modifiers: modifiers)
    }

    @objc(engineIsReservedKeyEvent:)
    func engineIsReservedKeyEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        return Shortcuts.isReserved(key: event.charactersIgnoringModifiers ?? "",
                                    unshiftedKey: event.charactersIgnoringModifiers ?? "",
                                    modifiers: event.modifierFlags)
    }
}
