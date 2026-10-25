import XCTest
@testable import ArchideaCore

final class SplitTests: XCTestCase {
    private func makeSpace() -> Space { Space(name: "Work", symbol: "briefcase", colorHex: "#7C8CF8") }

    func testASplitTakesTheFirstTabsPlace() {
        let space = makeSpace()
        let a = SidebarItem(tab: "https://a.example"), b = SidebarItem(tab: "https://b.example"), c = SidebarItem(tab: "https://c.example")
        space.today = [a, b, c]
        guard let split = space.makeSplit(b, with: c) else { return XCTFail("no split") }
        XCTAssertEqual(space.today.count, 2)
        XCTAssertTrue(space.today[1] === split)
        XCTAssertTrue(split.children[0] === b && split.children[1] === c)
        XCTAssertTrue(space.split(containing: c) === split)
        XCTAssertTrue(space.row(of: b) === split)
        XCTAssertFalse(space.isPinned(b))
        XCTAssertEqual(space.allTabs.map(\.url), ["https://a.example", "https://b.example", "https://c.example"])
    }

    func testTheSecondTabCanGoOnTheLeft() {
        let space = makeSpace()
        let a = SidebarItem(tab: "https://a.example"), b = SidebarItem(tab: "https://b.example")
        space.today = [a, b]
        let split = space.makeSplit(a, with: b, secondFirst: true)
        XCTAssertTrue(split?.children.first === b)
    }

    func testOnlyTabsOfTheirOwnSplit() {
        let space = makeSpace()
        let a = SidebarItem(tab: "https://a.example"), b = SidebarItem(tab: "https://b.example"), c = SidebarItem(tab: "https://c.example")
        let folder = SidebarItem(folder: "F")
        space.pinned = [folder]
        space.today = [a, b, c]
        XCTAssertNil(space.makeSplit(a, with: folder))
        XCTAssertNil(space.makeSplit(a, with: a))
        space.makeSplit(a, with: b)
        XCTAssertNil(space.makeSplit(c, with: a), "a is already in a split")
    }

    func testClosingOneSideLeavesTheOtherTabInItsPlace() {
        let space = makeSpace()
        let a = SidebarItem(tab: "https://a.example"), b = SidebarItem(tab: "https://b.example"), c = SidebarItem(tab: "https://c.example")
        space.today = [a, b, c]
        space.makeSplit(a, with: b)
        space.remove(a)
        XCTAssertEqual(space.today.map(\.url), ["https://b.example", "https://c.example"])
        XCTAssertTrue(space.today.allSatisfy(\.isTab))
        XCTAssertNil(space.split(containing: b))
    }

    func testSeparatingPutsBothTabsWhereTheSplitWas() {
        let space = makeSpace()
        let a = SidebarItem(tab: "https://a.example"), b = SidebarItem(tab: "https://b.example"), c = SidebarItem(tab: "https://c.example")
        space.today = [c, a, b]
        guard let split = space.makeSplit(a, with: b) else { return XCTFail("no split") }
        space.separate(split)
        XCTAssertEqual(space.today.map(\.url), ["https://c.example", "https://a.example", "https://b.example"])
    }

    func testAPinnedSplitKeepsItsTabsHomesAndTodayDropsThem() {
        let space = makeSpace()
        let a = SidebarItem(tab: "https://a.example/page"), b = SidebarItem(tab: "https://b.example/page")
        space.pinned = [a]
        space.today = [b]
        guard let split = space.makeSplit(a, with: b) else { return XCTFail("no split") }
        XCTAssertTrue(space.pinned.first === split)
        XCTAssertTrue(space.today.isEmpty)
        XCTAssertEqual(b.pinnedURL, "https://b.example/page")
        XCTAssertTrue(space.isPinned(b))
        space.move(split, to: .today, at: 0)
        XCTAssertNil(a.pinnedURL)
        XCTAssertNil(b.pinnedURL)
        XCTAssertFalse(space.isPinned(a))
    }

    func testASplitGoesIntoAFolderLikeATab() {
        let space = makeSpace()
        let folder = SidebarItem(folder: "F")
        let a = SidebarItem(tab: "https://a.example"), b = SidebarItem(tab: "https://b.example")
        space.pinned = [folder]
        space.today = [a, b]
        guard let split = space.makeSplit(a, with: b) else { return XCTFail("no split") }
        space.move(split, to: .folder(folder), at: 0)
        XCTAssertTrue(folder.children.first === split)
        XCTAssertTrue(space.split(containing: b) === split)
        XCTAssertEqual(space.location(of: b)?.inToday, false)
        XCTAssertEqual(b.pinnedURL, "https://b.example")
    }

    func testAClosedSideComesBackWhereItsSplitWas() {
        let state = AppState()
        let space = state.currentSpace
        let a = SidebarItem(tab: "https://a.example"), b = SidebarItem(tab: "https://b.example")
        space.today = [SidebarItem(tab: "https://other.example"), a, b]
        space.makeSplit(a, with: b)
        state.remember(b)
        space.remove(b)
        let reopened = state.reopenLastClosed(fallback: space)
        XCTAssertNil(reopened?.item.pinnedURL, "a Today split's tab comes back to Today")
        XCTAssertTrue(space.today.first === reopened?.item)
    }

    func testRememberingASplitRemembersBothTabs() {
        let state = AppState()
        let space = state.currentSpace
        let a = SidebarItem(tab: "https://a.example"), b = SidebarItem(tab: "https://b.example")
        space.today = [a, b]
        guard let split = space.makeSplit(a, with: b) else { return XCTFail("no split") }
        state.remember(split)
        XCTAssertEqual(state.recentlyClosed.map(\.url), ["https://a.example", "https://b.example"])
    }

    func testEitherSideInFrontKeepsTheSplit() {
        let state = AppState()
        let space = state.currentSpace
        let a = SidebarItem(tab: "https://a.example"), b = SidebarItem(tab: "https://b.example")
        space.today = [a, b]
        guard let split = space.makeSplit(a, with: b) else { return XCTFail("no split") }
        state.windows[0].select(b.id, in: space)
        XCTAssertTrue(state.isInFront(split, in: space))
    }

    func testRepairBreaksASplitThatHoldsTheWrongThings() {
        let state = AppState()
        let space = state.currentSpace
        let a = SidebarItem(tab: "https://a.example")
        let lonely = SidebarItem(split: a, SidebarItem(tab: "https://b.example"))
        lonely.children = [a]
        space.today = [lonely]
        XCTAssertTrue(state.repair())
        XCTAssertTrue(space.today.first === a)
        XCTAssertFalse(state.repair())
    }

    func testASplitRoundTripsAndAnOlderReadingSeesAFolder() throws {
        let state = AppState()
        let space = state.currentSpace
        let a = SidebarItem(tab: "https://a.example", title: "A"), b = SidebarItem(tab: "https://b.example", title: "B")
        space.today = [a, b]
        guard let split = space.makeSplit(a, with: b) else { return XCTFail("no split") }
        split.splitRatio = 0.6
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(AppState.self, from: data)
        let item = back.currentSpace.today.first
        XCTAssertEqual(item?.kind, .split)
        XCTAssertEqual(item?.splitRatio, 0.6)
        XCTAssertEqual(item?.children.map(\.url), ["https://a.example", "https://b.example"])
        XCTAssertEqual(item?.displayTitle, "A · B")
        // An unknown kind with children reads as a folder: what a version before splits makes of one.
        let older = #"{"kind": "pane-group", "children": [{"url": "https://a.example"}, {"url": "https://b.example"}]}"#
        XCTAssertEqual(try JSONDecoder().decode(SidebarItem.self, from: Data(older.utf8)).kind, .folder)
    }
}
