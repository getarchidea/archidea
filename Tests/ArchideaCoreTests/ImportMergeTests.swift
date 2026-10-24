import XCTest
@testable import ArchideaCore

final class ImportMergeTests: XCTestCase {
    private let anySymbol: (String) -> Bool = { _ in true }

    private func arc() -> [ImportedSpace] {
        [ImportedSpace(name: "Work", colorHex: "#4FB3D9", symbol: "briefcase",
                       pinned: [.tab(url: "https://mail.example", title: "Mail"),
                                .folder(title: "Docs", symbol: "doc.text", children: [.tab(url: "https://docs.example", title: "Docs")],
                                        expanded: false)],
                       tabs: [.tab(url: "https://news.example", title: "News")])]
    }

    func testAnUntouchedStartingSpaceMakesWayForImportedOnes() {
        let state = AppState()
        let counts = state.adopt(imported: arc(), openTabs: [], into: state.currentSpace, symbolExists: anySymbol)
        XCTAssertEqual(counts.spaces, 1)
        XCTAssertEqual(counts.pins, 2)
        XCTAssertEqual(counts.tabs, 1)
        XCTAssertEqual(state.spaces.map(\.name), ["Work"])
        XCTAssertEqual(state.currentSpace.name, "Work")
        let docs = state.currentSpace.pinned.last
        XCTAssertEqual(docs?.isFolder, true)
        XCTAssertEqual(docs?.expanded, false)
        XCTAssertEqual(docs?.children.first?.pinnedURL, "https://docs.example")
        XCTAssertNil(state.currentSpace.today.first?.pinnedURL)
    }

    func testWindowsOnTheDroppedStartingSpaceShowTheImportedOne() {
        let state = AppState()
        let starting = state.currentSpace
        let second = WindowState(spaceID: starting.id)
        state.windows.append(second)
        _ = state.adopt(imported: arc(), openTabs: [], into: starting, symbolExists: anySymbol)
        XCTAssertEqual(state.windows.map(\.spaceID), [state.spaces[0].id, state.spaces[0].id])
    }

    func testImportingTwiceAddsNothingTheSecondTime() {
        let state = AppState()
        _ = state.adopt(imported: arc(), openTabs: [], into: state.currentSpace, symbolExists: anySymbol)
        let again = state.adopt(imported: arc(), openTabs: [], into: state.currentSpace, symbolExists: anySymbol)
        XCTAssertEqual(again.spaces, 0)
        XCTAssertEqual(again.pins, 0)
        XCTAssertEqual(again.tabs, 0)
        XCTAssertEqual(state.currentSpace.pinned.count, 2)
        XCTAssertEqual(state.currentSpace.pinned.last?.children.count, 1)
    }

    func testFoldersAmongOpenTabsLandWithThePins() {
        let state = AppState()
        let space = state.currentSpace
        space.today = [SidebarItem(tab: "https://already.example")]
        let open: [ImportedNode] = [.tab(url: "https://already.example", title: ""),
                                    .tab(url: "https://new.example", title: ""),
                                    .folder(title: "Group", symbol: nil, children: [.tab(url: "https://g.example", title: "")], expanded: true)]
        let counts = state.adopt(imported: [], openTabs: open, into: space, symbolExists: anySymbol)
        XCTAssertEqual(counts.tabs, 1)
        XCTAssertEqual(counts.pins, 1)
        XCTAssertEqual(space.today.map(\.url), ["https://new.example", "https://already.example"])
        XCTAssertTrue(space.today.allSatisfy { !$0.isFolder })
        XCTAssertEqual(space.pinned.first?.title, "Group")
    }

    func testSymbolsThisMacLacksGiveWayToOurs() {
        let state = AppState()
        _ = state.adopt(imported: arc(), openTabs: [], into: state.currentSpace, symbolExists: { _ in false })
        XCTAssertTrue(SpaceStyle.symbols.contains(state.currentSpace.symbol))
        XCTAssertNil(state.currentSpace.pinned.last?.icon)
    }
}
