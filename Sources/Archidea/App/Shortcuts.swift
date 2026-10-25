import AppKit
import ArchideaCore

enum Shortcuts {
    private struct Key: Hashable {
        let key: String
        let modifiers: UInt
    }

    private static let relevant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    /// Keys the page never sees: the app handles them first, even while a web page has focus.
    private static var reserved = Set<Key>()

    static func isReserved(key: String, unshiftedKey: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        let mods = modifiers.intersection(relevant).rawValue
        return reserved.contains(Key(key: key.lowercased(), modifiers: mods))
            || reserved.contains(Key(key: unshiftedKey.lowercased(), modifiers: mods))
    }

    static func buildMainMenu(target: AppDelegate) -> NSMenu {
        reserved.removeAll()
        let main = NSMenu()

        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command,
                  reserve: Bool = false, tag: Int = 0, nilTarget: Bool = false) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = nilTarget ? nil : target
            item.tag = tag
            if reserve, !key.isEmpty {
                reserved.insert(Key(key: key.lowercased(), modifiers: mods.intersection(relevant).rawValue))
            }
            return item
        }

        func menu(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            items.forEach(sub.addItem)
            holder.submenu = sub
            main.addItem(holder)
        }

        let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        let tab = "\t"

        menu(L("menu.app"), [
            item(L("menu.checkUpdates"), #selector(AppDelegate.checkForUpdates)),
            .separator(),
            item(L("menu.settings"), #selector(AppDelegate.settings), ","),
            .separator(),
            item(L("menu.hide"), #selector(NSApplication.hide(_:)), "h", nilTarget: true),
            item(L("menu.hideOthers"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], nilTarget: true),
            .separator(),
            item(L("menu.quit"), #selector(AppDelegate.quit), "q", reserve: true),
        ])
        menu(L("menu.file"), [
            item(L("menu.newTab"), #selector(AppDelegate.newTab), "t", reserve: true),
            item(L("menu.newWindow"), #selector(AppDelegate.newWindow), "n", reserve: true),
            item(L("menu.newPrivateWindow"), #selector(AppDelegate.newPrivateWindow), "n", [.command, .shift], reserve: true),
            item(L("menu.openLocation"), #selector(AppDelegate.openLocation), "l", reserve: true),
            item(L("menu.newFolder"), #selector(AppDelegate.newFolder), "n", [.command, .option]),
            item(L("menu.newLiveFolder"), #selector(AppDelegate.newLiveFolder), ""),
            item(L("menu.newSpace"), #selector(AppDelegate.newSpace), "n", [.command, .control]),
            item(L("menu.import"), #selector(AppDelegate.importData), ""),
            .separator(),
            item(L("menu.closeTab"), #selector(AppDelegate.closeTab), "w", reserve: true),
            item(L("menu.closeWindow"), #selector(AppDelegate.closeWindow), "w", [.command, .shift], reserve: true),
            item(L("menu.reopenClosedTab"), #selector(AppDelegate.reopenClosedTab), "t", [.command, .shift], reserve: true),
            item(L("menu.togglePin"), #selector(AppDelegate.togglePin), "d", reserve: true),
            item(L("menu.copyURL"), #selector(AppDelegate.copyURL), "c", [.command, .shift], reserve: true),
        ])
        menu(L("menu.edit"), [
            item(L("menu.undo"), Selector(("undo:")), "z", nilTarget: true),
            item(L("menu.redo"), Selector(("redo:")), "z", [.command, .shift], nilTarget: true),
            .separator(),
            item(L("menu.cut"), #selector(NSText.cut(_:)), "x", nilTarget: true),
            item(L("menu.copy"), #selector(NSText.copy(_:)), "c", nilTarget: true),
            item(L("menu.paste"), #selector(NSText.paste(_:)), "v", nilTarget: true),
            item(L("menu.pastePlain"), #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .shift, .option], nilTarget: true),
            item(L("menu.selectAll"), #selector(NSText.selectAll(_:)), "a", nilTarget: true),
            .separator(),
            item(L("menu.find"), #selector(AppDelegate.find), "f"),
        ])
        menu(L("menu.view"), [
            item(L("menu.toggleSidebar"), #selector(AppDelegate.toggleSidebar), "s", reserve: true),
            .separator(),
            item(L("menu.reload"), #selector(AppDelegate.reload), "r"),
            item(L("menu.hardReload"), #selector(AppDelegate.hardReload), "r", [.command, .shift]),
            .separator(),
            item(L("menu.zoomIn"), #selector(AppDelegate.zoomIn), "="),
            item(L("menu.zoomOut"), #selector(AppDelegate.zoomOut), "-"),
            item(L("menu.actualSize"), #selector(AppDelegate.zoomReset), "0"),
            .separator(),
            item(L("menu.devTools"), #selector(AppDelegate.devTools), "i", [.command, .option], reserve: true),
        ])
        menu(L("menu.historyMenu"), [
            item(L("menu.back"), #selector(AppDelegate.goBack), "["),
            item(L("menu.forward"), #selector(AppDelegate.goForward), "]"),
            .separator(),
            item(L("menu.history"), #selector(AppDelegate.history), "y"),
            item(L("menu.downloads"), #selector(AppDelegate.downloads), "j", [.command, .shift]),
            item(L("menu.passwords"), #selector(AppDelegate.passwords), "p", [.command, .option]),
            item(L("menu.webStore"), #selector(AppDelegate.extensionsStore), ""),
        ])
        var tabs: [NSMenuItem] = [
            item(L("menu.nextTab"), #selector(AppDelegate.nextTab), tab, .control, reserve: true),
            item(L("menu.previousTab"), #selector(AppDelegate.previousTab), tab, [.control, .shift], reserve: true),
            item(L("menu.nextSpace"), #selector(AppDelegate.nextSpace), right, [.command, .option], reserve: true),
            item(L("menu.previousSpace"), #selector(AppDelegate.previousSpace), left, [.command, .option], reserve: true),
            .separator(),
            item(L("menu.splitView"), #selector(AppDelegate.newSplit), "\\", [.command, .option], reserve: true),
            .separator(),
        ]
        for number in 1...9 {
            tabs.append(item(L("menu.tabNumber", number), #selector(AppDelegate.selectTabByNumber(_:)), "\(number)", reserve: true, tag: number))
        }
        menu(L("menu.tabs"), tabs)
        menu(L("menu.window"), [
            item(L("menu.minimize"), #selector(NSWindow.performMiniaturize(_:)), "m", nilTarget: true),
            item(L("menu.zoom"), #selector(NSWindow.performZoom(_:)), "", nilTarget: true),
        ])
        menu(L("menu.help"), [
            item(L("menu.saveDiagnostics"), #selector(AppDelegate.saveDiagnostics)),
            item(L("menu.reportIssue"), #selector(AppDelegate.reportIssue)),
        ])
        return main
    }
}
