import Foundation
import ArchideaCore

/// Short names for tabs with long titles (Settings → AI), for the normal windows' sidebar. It asks a few seconds after
/// titles change, for all the tabs waiting at once, so a burst of page loads costs one small request. A tab it named,
/// or that the AI left as it is, isn't asked about again until its page has another title. When the service fails it
/// stays quiet: it waits ten minutes, or for Settings to change when the key or the account is the trouble.
final class SmartTitlesRunner {
    private unowned let group: WindowGroup
    private var timer: Timer?
    private var running = false
    private var resumeAt = Date.distantPast

    init(group: WindowGroup) { self.group = group }

    /// A page's title changed somewhere.
    func titlesChanged() { schedule(after: 4) }

    /// Settings → AI changed: a failure waited on may be fixed.
    func settingsChanged() {
        resumeAt = .distantPast
        schedule(after: 1)
    }

    private func schedule(after seconds: TimeInterval) {
        guard AIService.shared.settings.shortTitles, AIService.shared.isConnected else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.run() }
    }

    private func run() {
        let ai = AIService.shared
        guard ai.settings.shortTitles, ai.isConnected, !running, Date() >= resumeAt else { return }
        var seen = Set<UUID>()
        let waiting = group.store.state.spaces.flatMap(\.allTabs).filter { seen.insert($0.id).inserted && SmartTitles.wants($0) }
        let tabs = Array(waiting.prefix(SmartTitles.batch))
        guard !tabs.isEmpty else { return }
        let asked = tabs.map(\.title)
        running = true
        Task { @MainActor [weak self] in
            defer { self?.running = false }
            do {
                let answer = try await ai.complete(SmartTitles.request(for: tabs))
                let named = SmartTitles.parse(answer, tabs: tabs)
                for (tab, title) in zip(tabs, asked) where tab.title == title {
                    // Left unnamed: the title is fine as it is, and isn't asked about again.
                    tab.shortTitle = named.first { $0.0 === tab }?.1
                    tab.shortTitleOf = title
                }
                Trace.log("short titles: \(named.count) of \(tabs.count) tabs named")
                guard let self else { return }
                group.store.setNeedsSave()
                group.sidebarChanged(by: nil)
                if waiting.count > tabs.count { schedule(after: 1) }
            } catch {
                let failure = error as? AIError ?? .failed(error.localizedDescription)
                Trace.log("short titles: \(failure)")
                self?.resumeAt = failure.needsSettings ? .distantFuture : Date().addingTimeInterval(10 * 60)
            }
        }
    }
}
