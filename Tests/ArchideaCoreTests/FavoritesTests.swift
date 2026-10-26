import XCTest
@testable import ArchideaCore

final class FavoritesTests: XCTestCase {
    func testAFavoriteIsAPinInItsOwnFolder() {
        let state = AppState()
        let space = state.currentSpace
        let tab = SidebarItem(tab: "https://mail.example/inbox")
        space.today = [tab]
        space.move(tab, to: .folder(space.favorites), at: 0)
        XCTAssertTrue(space.isFavorite(tab))
        XCTAssertTrue(space.isPinned(tab))
        XCTAssertTrue(space.today.isEmpty)
        XCTAssertEqual(tab.pinnedURL, "https://mail.example/inbox", "it keeps its home address, like a pin")
        XCTAssertTrue(space.find(tab.id) === tab)
        XCTAssertTrue(state.space(containing: tab) === space)
        XCTAssertTrue(space.allTabs.first === tab, "favourites come first")
        XCTAssertTrue(space.location(of: tab)?.parent === space.favorites)
        XCTAssertTrue(space.slot(of: tab)?.same(.folder(space.favorites)) == true)
    }

    func testOneMovedOutLeavesAndOneClosedComesBack() {
        let state = AppState()
        let space = state.currentSpace
        let a = SidebarItem(tab: "https://a.example"), b = SidebarItem(tab: "https://b.example")
        space.today = [a, b]
        space.move(a, to: .folder(space.favorites), at: 0)
        space.move(b, to: .folder(space.favorites), at: 1)
        space.move(a, to: .today, at: 0)
        XCTAssertFalse(space.isFavorite(a))
        XCTAssertNil(a.pinnedURL)
        state.remember(b)
        space.remove(b)
        XCTAssertTrue(space.favorites.children.isEmpty)
        let reopened = state.reopenLastClosed(fallback: space)
        XCTAssertTrue(reopened.map { space.isFavorite($0.item) } == true, "⇧⌘T brings a favourite back among the favourites")
    }

    func testRepairKeepsOnlyTabsAmongTheFavorites() {
        let state = AppState()
        let space = state.currentSpace
        let folder = SidebarItem(folder: "F")
        let tab = SidebarItem(tab: "https://a.example")
        space.favorites.children = [folder, tab]
        XCTAssertTrue(state.repair())
        XCTAssertEqual(space.favorites.children.count, 1)
        XCTAssertTrue(space.pinned.contains { $0 === folder })
        XCTAssertEqual(tab.pinnedURL, "https://a.example")
        XCTAssertFalse(state.repair())
    }

    func testEverySpaceShowsTheSameFavorites() {
        let state = AppState()
        let work = Space(name: "Work", symbol: "briefcase", colorHex: "#7C8CF8")
        state.spaces.append(work)
        let home = state.spaces[0]
        XCTAssertTrue(work.favorites === home.favorites)
        XCTAssertTrue(work.favorites === state.favorites)
        let tab = SidebarItem(tab: "https://mail.example")
        work.today = [tab]
        work.move(tab, to: .folder(work.favorites), at: 0)
        XCTAssertTrue(home.isFavorite(tab))
        XCTAssertTrue(home.allTabs.first === tab)
        XCTAssertTrue(home.find(tab.id) === tab)
    }

    func testFavoritesRoundTripAndAnOlderFileHasNone() throws {
        let state = AppState()
        let space = state.currentSpace
        let tab = SidebarItem(tab: "https://a.example", title: "A")
        space.today = [tab]
        space.move(tab, to: .folder(space.favorites), at: 0)
        let back = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(back.favorites.children.map(\.url), ["https://a.example"])
        XCTAssertTrue(back.currentSpace.favorites === back.favorites)
        let older = #"{"name": "Old", "pinned": [], "today": []}"#
        let old = try JSONDecoder().decode(Space.self, from: Data(older.utf8))
        XCTAssertTrue(old.favorites.children.isEmpty)
        XCTAssertTrue(old.favorites.isFolder)
    }
}
