import AppKit
import ArchideaCore

/// How the window is laid out: the sidebar docked, hidden or slid out over the page, and the space's colours on it.
extension BrowserWindowController {
    // MARK: sidebar modes: docked, hidden, or slid out over the page

    func applySidebarMode(animated: Bool, duration: TimeInterval = 0.22) {
        let mode: RootView.SidebarMode = !windowState.sidebarHidden ? .docked : overlayShown ? .overlay : .hidden
        root.mode = mode
        root.contentFullscreen = contentFullscreen
        let fullscreen = window.styleMask.contains(.fullScreen)
        TrafficLights.setVisible(fullscreen || (mode != .hidden && !contentFullscreen), in: window, animated: animated)
        if animated { root.animateLayout(duration: duration) } else { root.needsLayout = true }
    }

    /// Where the page sits, in `view`'s coordinates.
    func pageFrame(in view: NSView) -> NSRect { view.convert(content.bounds, from: content) }

    /// Whether a press at this window point lands on the sidebar while it's on screen, docked or slid out.
    func sidebarTakesPress(at point: NSPoint) -> Bool {
        guard !contentFullscreen, !windowState.sidebarHidden || overlayShown else { return false }
        return sidebar.frame.contains(root.convert(point, from: nil))
    }

    func setOverlay(_ shown: Bool) {
        overlayHide?.cancel()
        overlayHide = nil
        guard overlayShown != shown, windowState.sidebarHidden else { return }
        overlayShown = shown
        applySidebarMode(animated: true)
    }

    /// The slid-out sidebar stays while something of it is in use: a rename, its menu, a popover or sheet it opened
    /// (an icon picker, the theme editor). The pointer wandering off doesn't put it away then.
    private var overlayHeld: Bool {
        // Only popovers among the child windows: the engine keeps child windows of its own (the link status bubble).
        sidebar.isBusy || window.attachedSheet != nil
            || (window.childWindows ?? []).contains { $0.isVisible && NSStringFromClass(type(of: $0)).contains("Popover") }
    }

    func trackPointer(_ event: NSEvent) {
        guard event.window === window, windowState.sidebarHidden, !contentFullscreen, !root.isResizing else { return }
        let point = root.convert(event.locationInWindow, from: nil)
        if !overlayShown {
            if point.x <= 6, point.y > 0, point.y < root.bounds.height { setOverlay(true) }
            return
        }
        if point.x > sidebar.frame.maxX + 24 {
            guard overlayHide == nil, !overlayHeld else { return }
            // Checked again when it fires: a rename chosen from the menu starts a moment after the menu closes.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                overlayHide = nil
                if !overlayHeld { setOverlay(false) }
            }
            overlayHide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        } else {
            overlayHide?.cancel()
            overlayHide = nil
        }
    }

    func toggleSidebar() {
        if windowState.sidebarHidden, overlayShown {
            windowState.sidebarHidden = false
            overlayShown = false
        } else {
            windowState.sidebarHidden.toggle()
            overlayShown = false
        }
        applySidebarMode(animated: true)
        store.setNeedsSave()
    }

    // MARK: the space's look

    func restyle(_ target: Space, color: String?, symbol: String?) {
        if let color { target.colorHex = color }
        if let symbol { target.symbol = symbol }
        if target === space { applyTheme(of: target) }
        reloadSidebar()
        store.setNeedsSave()
    }

    /// The space's colour, its strength and its light or dark window. The sidebar's text follows how light
    /// the tinted background really is, so it stays readable on a pale mint as on a deep purple.
    func applyTheme(of target: Space) {
        let tint = NSColor(hex: target.colorHex)
        let strength = CGFloat(target.tintStrength ?? Double(Theme.tintAlpha))
        root.tintStrength = strength
        sidebar.tintStrength = strength
        root.tint = tint
        sidebar.tint = tint
        // On our root view, not the window: Chrome owns the window and applies its appearance on its own schedule.
        // The app's own appearance (which the pages follow too) is the window in front's.
        let setsApp = !isPrivate && (window.isKeyWindow || group.front === self)
        let dark: Bool
        switch target.appearance ?? .system {
        case .system:
            if setsApp {
                root.appearance = nil
                NSApp.appearance = nil
                dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            } else {
                // Behind another window, whose space may have set the app light or dark: the system's own look.
                dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
                root.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            }
        case .light:
            root.appearance = NSAppearance(named: .aqua)
            if setsApp { NSApp.appearance = NSAppearance(named: .aqua) }
            dark = false
        case .dark:
            root.appearance = NSAppearance(named: .darkAqua)
            // A private window is always dark; it leaves the app's (and the other windows' pages') look alone.
            if setsApp { NSApp.appearance = NSAppearance(named: .darkAqua) }
            dark = true
        }
        // Chromium follows the app's appearance for pages' prefers-color-scheme, so sites switch with the space.
        let background = Theme.sidebarLuminance(dark: dark, tint: tint, strength: strength)
        sidebar.appearance = NSAppearance(named: background > 0.5 ? .aqua : .darkAqua)
    }

    func editTheme(_ target: Space, from view: NSView) {
        let current = ThemeEditor.Theme(color: NSColor(hex: target.colorHex),
                                        strength: CGFloat(target.tintStrength ?? Double(Theme.tintAlpha)),
                                        appearance: target.appearance ?? .system)
        let editor = ThemeEditor(theme: current) { [weak self] theme in
            guard let self else { return }
            target.colorHex = theme.color.hexString
            target.tintStrength = Double(theme.strength)
            target.appearance = theme.appearance == .system ? nil : theme.appearance
            if target === space { applyTheme(of: target) }
            reloadSidebar()
            store.setNeedsSave()
        }
        editor.present(relativeTo: view.bounds, of: view, edge: .maxX)
    }
}
