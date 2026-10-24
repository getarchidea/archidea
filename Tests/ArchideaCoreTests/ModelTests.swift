import XCTest
@testable import ArchideaCore

final class ModelTests: XCTestCase {
    private func makeSpace() -> Space { Space(name: "Work", symbol: "briefcase", colorHex: "#7C8CF8") }

    // MARK: what each list may hold

    func testFolderSentToTodayStaysAmongThePins() {
        let space = makeSpace()
        let folder = SidebarItem(folder: "Reading")
        folder.children = [SidebarItem(tab: "https://a.example")]
        space.pinned = [SidebarItem(tab: "https://b.example"), folder]
        space.move(folder, to: .today, at: 0)
        XCTAssertTrue(space.today.isEmpty)
        XCTAssertTrue(space.pinned.last === folder)
    }

    func testPinningKeepsTheHomeAddressAndTodayDropsIt() {
        let space = makeSpace()
        let tab = SidebarItem(tab: "https://a.example/page")
        space.today = [tab]
        space.move(tab, to: .pinned, at: 0)
        XCTAssertEqual(tab.pinnedURL, "https://a.example/page")
        XCTAssertTrue(space.pinned.first === tab)
        space.move(tab, to: .today, at: 0)
        XCTAssertNil(tab.pinnedURL)
        XCTAssertTrue(space.today.first === tab)
    }

    func testMovingDownWithinAListLandsWhereItWasLetGo() {
        let space = makeSpace()
        let tabs = (0..<4).map { SidebarItem(tab: "https://\($0).example") }
        space.today = tabs
        // Let go between the third and the fourth tab: index 3 as the list was before the move.
        space.move(tabs[0], to: .today, at: 3)
        XCTAssertEqual(space.today.map(\.url), [tabs[1], tabs[2], tabs[0], tabs[3]].map(\.url))
    }

    func testMovingIntoAFolderOpensItAndPinsTheTab() {
        let space = makeSpace()
        let folder = SidebarItem(folder: "Docs")
        folder.expanded = false
        let tab = SidebarItem(tab: "https://docs.example")
        space.pinned = [folder]
        space.today = [tab]
        space.move(tab, to: .folder(folder), at: 0)
        XCTAssertTrue(folder.children.first === tab)
        XCTAssertTrue(folder.expanded)
        XCTAssertEqual(tab.pinnedURL, "https://docs.example")
        XCTAssertTrue(space.today.isEmpty)
    }

    func testRepairPutsRightWhatABugSaved() {
        let state = AppState()
        let space = state.currentSpace
        let folder = SidebarItem(folder: "Stray")
        let homeless = SidebarItem(tab: "https://pinned.example")
        let stale = SidebarItem(tab: "https://today.example")
        stale.pinnedURL = "https://old.example"
        space.pinned = [homeless]
        space.today = [folder, stale]
        state.currentSpaceID = UUID()
        XCTAssertTrue(state.repair())
        XCTAssertEqual(space.today.count, 1)
        XCTAssertTrue(space.pinned.contains { $0 === folder })
        XCTAssertEqual(homeless.pinnedURL, "https://pinned.example")
        XCTAssertNil(stale.pinnedURL)
        XCTAssertEqual(state.currentSpaceID, space.id)
        XCTAssertFalse(state.repair())
    }

    func testStaleTodayLeavesFoldersRecentTabsAndKeptOnes() {
        let space = makeSpace()
        let old = SidebarItem(tab: "https://old.example")
        old.lastActive = Date(timeIntervalSinceNow: -48 * 3600)
        let kept = SidebarItem(tab: "https://kept.example")
        kept.lastActive = old.lastActive
        let fresh = SidebarItem(tab: "https://fresh.example")
        space.today = [old, kept, fresh]
        let stale = space.staleToday(before: Date(timeIntervalSinceNow: -12 * 3600)) { $0 === kept }
        XCTAssertEqual(stale.map(\.url), ["https://old.example"])
    }

    // MARK: recently closed

    func testAClosedPinComesBackToItsPlace() {
        let state = AppState()
        let space = state.currentSpace
        let folder = SidebarItem(folder: "Tools")
        let first = SidebarItem(tab: "https://one.example")
        let pin = SidebarItem(tab: "https://two.example/somewhere")
        pin.pinnedURL = "https://two.example"
        pin.customTitle = "Two"
        folder.children = [first, pin]
        space.pinned = [folder]
        state.remember(pin)
        space.remove(pin)
        guard let reopened = state.reopenLastClosed() else { return XCTFail("nothing to reopen") }
        XCTAssertTrue(reopened.space === space)
        XCTAssertTrue(folder.children.last === reopened.item)
        XCTAssertEqual(reopened.item.url, "https://two.example/somewhere")
        XCTAssertEqual(reopened.item.pinnedURL, "https://two.example")
        XCTAssertEqual(reopened.item.customTitle, "Two")
        XCTAssertTrue(state.recentlyClosed.isEmpty)
    }

    func testAClosedTodayTabComesBackOnTop() {
        let state = AppState()
        let space = state.currentSpace
        let tab = SidebarItem(tab: "https://closed.example", title: "Closed")
        space.today = [SidebarItem(tab: "https://open.example"), tab]
        state.remember(tab)
        space.remove(tab)
        let reopened = state.reopenLastClosed()
        XCTAssertTrue(space.today.first === reopened?.item)
        XCTAssertNil(reopened?.item.pinnedURL)
        XCTAssertEqual(reopened?.item.title, "Closed")
    }

    func testBlankTabsAndFoldersAreNotRemembered() {
        let state = AppState()
        let blank = SidebarItem(tab: "about:blank")
        let folder = SidebarItem(folder: "F")
        state.currentSpace.today = [blank]
        state.currentSpace.pinned = [folder]
        state.remember(blank)
        state.remember(folder)
        XCTAssertTrue(state.recentlyClosed.isEmpty)
    }

    func testTheReopenListIsBounded() {
        let state = AppState()
        for index in 0..<(AppState.closedLimit + 10) {
            let tab = SidebarItem(tab: "https://\(index).example")
            state.currentSpace.today = [tab]
            state.remember(tab)
        }
        XCTAssertEqual(state.recentlyClosed.count, AppState.closedLimit)
        XCTAssertEqual(state.recentlyClosed.last?.url, "https://\(AppState.closedLimit + 9).example")
    }

    func testBringingAClosedTabForward() {
        let state = AppState()
        for index in 0..<3 {
            let tab = SidebarItem(tab: "https://\(index).example")
            state.currentSpace.today = [tab]
            state.remember(tab)
        }
        // Counted from the newest: 0 is "2", 2 is "0".
        XCTAssertTrue(state.bringForward(closedAt: 2))
        XCTAssertEqual(state.recentlyClosed.last?.url, "https://0.example")
        XCTAssertFalse(state.bringForward(closedAt: 3))
    }

    // MARK: the saved file

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    func testAFileFromAnOlderVersionReads() throws {
        let json = """
        {
          "currentSpaceID": "9B5D3F1C-6C1E-4E9A-9A39-2C6D7C0E5A11",
          "sidebarHidden": false,
          "sidebarWidth": 260,
          "spaces": [{
            "colorHex": "#F28C6B", "id": "9B5D3F1C-6C1E-4E9A-9A39-2C6D7C0E5A11", "name": "Home", "symbol": "house",
            "pinned": [{
              "children": [], "expanded": true, "id": "0F8B7A4E-3B9F-4E0C-8C52-6A2E1B9D7F33", "kind": "tab",
              "lastActive": "2026-01-02T10:00:00Z", "pinnedURL": "https://news.example", "title": "News",
              "url": "https://news.example/today"
            }],
            "today": []
          }]
        }
        """
        let state = try decoder.decode(AppState.self, from: Data(json.utf8))
        XCTAssertEqual(state.sidebarWidth, 260)
        XCTAssertEqual(state.currentSpace.name, "Home")
        XCTAssertEqual(state.currentSpace.pinned.first?.pinnedURL, "https://news.example")
        XCTAssertNil(state.currentSpace.pinned.first?.customTitle)
        XCTAssertTrue(state.recentlyClosed.isEmpty)
        XCTAssertEqual(state.version, AppState.schemaVersion)
        // Settings saved before cookie banners were hidden take the default: on.
        XCTAssertTrue(state.settings.hideCookieBanners)
    }

    func testFieldsFromANewerVersionAreSkipped() throws {
        let json = """
        {"spaces": [{"name": "Home", "pinned": [{"kind": "liveFolder", "children": [{"url": "https://a.example"}],
        "somethingNew": 1}], "appearance": "sepia"}], "futureField": true}
        """
        let state = try decoder.decode(AppState.self, from: Data(json.utf8))
        let item = state.currentSpace.pinned.first
        XCTAssertEqual(item?.kind, .folder)
        XCTAssertEqual(item?.children.first?.url, "https://a.example")
        XCTAssertNil(state.currentSpace.appearance)
        XCTAssertEqual(state.currentSpaceID, state.currentSpace.id)
    }

    func testADamagedFileStillFails() {
        let json = #"{"spaces": [{"name": "Home", "pinned": 5}]}"#
        XCTAssertThrowsError(try decoder.decode(AppState.self, from: Data(json.utf8)))
    }

    func testTheSidebarRoundTrips() throws {
        let state = AppState()
        let folder = SidebarItem(folder: "F")
        folder.icon = "star"
        let pin = SidebarItem(tab: "https://pin.example", title: "Pin")
        pin.pinnedURL = pin.url
        pin.customTitle = "Mine"
        folder.children = [pin]
        state.currentSpace.pinned = [folder]
        state.currentSpace.today = [SidebarItem(tab: "https://today.example")]
        state.currentSpace.appearance = .dark
        state.remember(state.currentSpace.today[0])
        var settings = state.settings
        settings.searchEngine = .duckduckgo
        state.settings = settings
        let back = try decoder.decode(AppState.self, from: encoder.encode(state))
        let space = back.currentSpace
        XCTAssertEqual(space.id, state.currentSpace.id)
        XCTAssertEqual(space.appearance, .dark)
        XCTAssertEqual(space.pinned.first?.icon, "star")
        XCTAssertEqual(space.pinned.first?.children.first?.customTitle, "Mine")
        XCTAssertEqual(space.today.first?.url, "https://today.example")
        XCTAssertEqual(back.recentlyClosed, state.recentlyClosed)
        XCTAssertEqual(back.settings.searchEngine, .duckduckgo)
    }
}
