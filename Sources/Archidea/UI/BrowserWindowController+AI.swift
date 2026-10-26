import AppKit
import ArchideaCore

/// What the AI does from the sidebar, when asked: names a tab, and tidies Today into folders. While it works, the
/// rows it works on glow; then the change simply happens. Only a failure says anything.
extension BrowserWindowController {
    /// Spaces whose Today is being tidied and tabs being named, so a second click doesn't ask twice.
    private enum Working {
        static var items = Set<UUID>()
    }

    var renamesWithAI: Bool { usesAI && settings.ai.rename }

    /// Today holds enough tabs to group, and the AI is there to group them.
    var tidiesToday: Bool {
        usesAI && settings.ai.tidy && space.today.filter(\.isTab).count >= TidyToday.minimum && !Working.items.contains(space.id)
    }

    /// The tab gets a short name made of its page's title, as if the person had renamed it (Reset Name undoes it).
    func renameWithAI(_ item: SidebarItem) {
        guard renamesWithAI, item.isTab, Working.items.insert(item.id).inserted else { return }
        let glow = sidebar.glow(over: [item])
        Trace.log("rename with AI: \(item.traceName)")
        Task { @MainActor [weak self] in
            defer {
                Working.items.remove(item.id)
                glow?.stop()
            }
            do {
                let answer = try await AIService.shared.complete(TabNaming.request(for: item))
                guard let self, let name = TabNaming.parse(answer) else { throw AIError.unreadable }
                item.customTitle = name
                sidebar.reloadItem(item)
                group.itemChanged(item, by: self)
                store.setNeedsSave()
            } catch {
                self?.showAIError(error as? AIError ?? .failed(error.localizedDescription))
            }
        }
    }

    /// Groups Today's tabs by topic, each group a folder at the end of the pins (folders live there), its tabs in it.
    func tidyToday() {
        guard tidiesToday else { return }
        let target = space
        // Splits stay as they are; titles and sites are all that's sent.
        let tabs = target.today.filter(\.isTab)
        Working.items.insert(target.id)
        sidebar.reload()
        let glow = sidebar.glow(over: tabs)
        Trace.log("tidy today: \(tabs.count) tabs")
        Task { @MainActor [weak self] in
            defer {
                Working.items.remove(target.id)
                glow?.stop()
            }
            do {
                let answer = try await AIService.shared.complete(TidyToday.request(for: tabs))
                guard let self else { return }
                applyTidy(TidyToday.parse(answer, tabs: tabs), in: target)
            } catch {
                guard let self else { return }
                sidebar.reload()
                showAIError(error as? AIError ?? .failed(error.localizedDescription))
            }
        }
    }

    private func applyTidy(_ groups: [TidyToday.Group], in target: Space) {
        var made = 0
        for group in groups {
            let tabs = group.tabs.filter { tab in target.today.contains { $0 === tab } }
            guard tabs.count >= 2 else { continue }
            let folder = SidebarItem(folder: group.name)
            target.place(folder, in: .pinned, at: target.pinned.count)
            for tab in tabs { target.move(tab, to: .folder(folder), at: folder.children.count) }
            made += 1
        }
        Trace.log("tidy today: \(made) folders made")
        sidebar.reload(fading: true)
        group.sidebarChanged(by: self)
        store.setNeedsSave()
    }

    /// A card saying what went wrong, with the way to Settings when that's where it's fixed.
    func showAIError(_ error: AIError) {
        var buttons: [PromptCard.Button] = [.init(title: "OK", style: error.needsSettings ? .secondary : .primary) { _ in }]
        if error.needsSettings {
            buttons.append(.init(title: L("ai.settings.open"), style: .primary) { _ in SettingsWindowController.shared.show(section: .ai) })
        }
        sitePrompts.add(.init(id: "ai-error", tab: nil, belongsToTab: false, icon: NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil),
                              host: L("ai.name"), title: L("ai.error.title"), detail: error.message, buttons: buttons, dismissed: {}))
    }
}
