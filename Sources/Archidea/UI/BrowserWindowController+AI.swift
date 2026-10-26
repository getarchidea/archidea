import AppKit
import ArchideaCore

/// Tidy Today: the AI groups Today's tabs by topic, a card shows the groups, and on "Tidy" each becomes a folder
/// among the pins (folders live there), its tabs in it.
extension BrowserWindowController {
    /// Today holds enough tabs to group, and the AI is there to group them.
    var tidiesToday: Bool {
        usesAI && settings.ai.tidy && space.today.filter(\.isTab).count >= TidyToday.minimum
    }

    func tidyToday() {
        guard tidiesToday else { return }
        let target = space
        // Splits stay as they are; titles and sites are all that's sent.
        let tabs = target.today.filter(\.isTab)
        let id = "tidy-\(target.id)"
        let icon = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        var task: Task<Void, Never>?
        sitePrompts.add(.init(id: id, tab: nil, belongsToTab: false, icon: icon, host: L("ai.name"), title: L("ai.tidy.working"),
                              detail: plural("count.tabs", tabs.count),
                              buttons: [.init(title: L("common.cancel"), style: .secondary) { _ in task?.cancel() }],
                              dismissed: { task?.cancel() }))
        Trace.log("tidy today: \(tabs.count) tabs")
        task = Task { @MainActor [weak self] in
            do {
                let answer = try await AIService.shared.complete(TidyToday.request(for: tabs))
                guard let self, !Task.isCancelled else { return }
                sitePrompts.remove(id: id)
                let groups = TidyToday.parse(answer, tabs: tabs)
                Trace.log("tidy today: \(groups.count) groups")
                guard !groups.isEmpty else { return showNotice(L("ai.tidy.nothing"), detail: nil) }
                let list = groups.map { "\($0.name) — \(plural("count.tabs", $0.tabs.count))" }.joined(separator: "\n")
                sitePrompts.add(.init(id: id, tab: nil, belongsToTab: false, icon: icon, host: L("ai.name"),
                                      title: L("ai.tidy.title"), detail: list + "\n\n" + L("ai.tidy.note"),
                                      buttons: [.init(title: L("common.cancel"), style: .secondary) { _ in },
                                                .init(title: L("ai.tidy.apply"), style: .primary) { [weak self] _ in
                                                    self?.applyTidy(groups, in: target)
                                                }],
                                      dismissed: {}))
            } catch {
                guard let self, !Task.isCancelled else { return }
                sitePrompts.remove(id: id)
                showAIError(error as? AIError ?? .failed(error.localizedDescription))
            }
        }
    }

    /// Each group becomes a folder at the end of the pins, with the tabs that are still in Today.
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
        reloadSidebar()
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
