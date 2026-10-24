import AppKit
import ArchideaCore

/// How the window is laid out: the sidebar docked, hidden or slid out over the page, and the space's colours on it.
extension BrowserWindowController {
    // MARK: sidebar modes: docked, hidden, or slid out over the page

    func applySidebarMode(animated: Bool, duration: TimeInterval = 0.22) {
        let mode: RootView.SidebarMode = !state.sidebarHidden ? .docked : overlayShown ? .overlay : .hidden
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
        guard !contentFullscreen, !state.sidebarHidden || overlayShown else { return false }
        return sidebar.frame.contains(root.convert(point, from: nil))
    }

    func setOverlay(_ shown: Bool) {
        overlayHide?.cancel()
        overlayHide = nil
        guard overlayShown != shown, state.sidebarHidden else { return }
        overlayShown = shown
        applySidebarMode(animated: true)
    }

    func trackPointer(_ event: NSEvent) {
        guard event.window === window, state.sidebarHidden, !contentFullscreen, !root.isResizing else { return }
        let point = root.convert(event.locationInWindow, from: nil)
        if !overlayShown {
            if point.x <= 6, point.y > 0, point.y < root.bounds.height { setOverlay(true) }
            return
        }
        if point.x > sidebar.frame.maxX + 24 {
            guard overlayHide == nil else { return }
            let work = DispatchWorkItem { [weak self] in self?.setOverlay(false) }
            overlayHide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        } else {
            overlayHide?.cancel()
            overlayHide = nil
        }
    }

    func toggleSidebar() {
        if state.sidebarHidden, overlayShown {
            state.sidebarHidden = false
            overlayShown = false
        } else {
            state.sidebarHidden.toggle()
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
        sidebar.reload()
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
        let dark: Bool
        switch target.appearance ?? .system {
        case .system:
            root.appearance = nil
            if !isPrivate { NSApp.appearance = nil }
            dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        case .light:
            root.appearance = NSAppearance(named: .aqua)
            if !isPrivate { NSApp.appearance = NSAppearance(named: .aqua) }
            dark = false
        case .dark:
            root.appearance = NSAppearance(named: .darkAqua)
            // A private window is always dark; it leaves the app's (and the main window's pages') look alone.
            if !isPrivate { NSApp.appearance = NSAppearance(named: .darkAqua) }
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
            sidebar.reload()
            store.setNeedsSave()
        }
        editor.present(relativeTo: view.bounds, of: view, edge: .maxX)
    }
}
