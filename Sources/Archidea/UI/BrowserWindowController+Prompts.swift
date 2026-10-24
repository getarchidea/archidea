import AppKit
import ArchideaCore
import ArdiaCore

/// Cards in the page's corner instead of dialogs: a site's permission requests, an extension asking to be installed,
/// and the app's own questions and notices.
extension BrowserWindowController {
    func showPermissionRequest(_ request: [String: Any], tab: ArdiaCoreTab) {
        sitePrompts.addPermissionRequest(request, tab: tab)
    }

    func runtime(_ runtime: TabRuntime, tab: ArdiaCoreTab, asksToOpenApp request: [String: Any]) {
        sitePrompts.addExternalAppRequest(request, tab: tab)
    }

    /// A line of text from the user (a space's name), as a card instead of a modal alert.
    func ask(_ title: String, placeholder: String, value: String = "", confirm: String, completion: @escaping (String) -> Void) {
        showWindow()
        sitePrompts.add(.init(id: "ask-\(title)", tab: nil, belongsToTab: false, icon: IconChoice.preview(IconChoice.current),
                              host: L("app.name"), title: title, fields: [.init(placeholder: placeholder, value: value, secure: false)],
                              focusesField: true, buttons: [
                                  .init(title: L("common.cancel"), style: .secondary) { _ in },
                                  .init(title: confirm, style: .primary) { values in
                                      let text = values.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                      if !text.isEmpty { completion(text) }
                                  },
                              ], dismissed: {}))
    }

    /// A yes-or-no about a site (clearing its data, say), on the site's own card.
    func confirm(host: String, icon: NSImage?, title: String, detail: String?, confirm: String, action: @escaping () -> Void) {
        sitePrompts.add(.init(id: "confirm-\(title)", tab: nil, belongsToTab: false, icon: icon, host: host, title: title, detail: detail,
                              buttons: [.init(title: L("common.cancel"), style: .secondary) { _ in },
                                        .init(title: confirm, style: .primary) { _ in action() }],
                              dismissed: {}))
    }

    /// A short message from the app itself (an update check, say), as a card instead of an alert.
    func showNotice(_ title: String, detail: String?) {
        showWindow()
        sitePrompts.add(.init(id: "notice-\(title)", tab: nil, belongsToTab: false, icon: IconChoice.preview(IconChoice.current),
                              host: L("app.name"), title: title, detail: detail,
                              buttons: [.init(title: "OK", style: .primary) { _ in }], dismissed: {}))
    }

    func dismissPermissionRequest(_ id: String) {
        sitePrompts.remove(id: id)
    }

    func showExtensionInstallPrompt(_ prompt: [String: Any]) {
        let id = prompt["requestId"] as? String ?? ""
        let name = prompt["name"] as? String ?? L("extensions.unnamed")
        let permissions = prompt["permissions"] as? [String] ?? []
        let detail = permissions.isEmpty ? nil : L("extensions.install.can") + "\n• " + permissions.prefix(6).joined(separator: "\n• ")
        let icon = prompt["icon"] as? NSImage ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
        sitePrompts.add(.init(id: "install-\(id)", tab: nil, belongsToTab: false, icon: icon, host: L("extensions.install.source"),
                              title: L("extensions.install.title", name), detail: detail, buttons: [
                                  .init(title: L("common.cancel"), style: .secondary) { _ in
                                      ArdiaCoreEngine.resolveExtensionInstallPrompt(id, accepted: false)
                                  },
                                  .init(title: L("extensions.install"), style: .primary) { _ in
                                      ArdiaCoreEngine.resolveExtensionInstallPrompt(id, accepted: true)
                                  },
                              ], dismissed: { ArdiaCoreEngine.resolveExtensionInstallPrompt(id, accepted: false) }))
    }
}
