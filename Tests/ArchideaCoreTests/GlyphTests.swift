import XCTest
@testable import ArchideaCore

final class GlyphTests: XCTestCase {
    func testEmojiAreToldFromSymbolNames() {
        for emoji in ["🏠", "❤️", "⭐️", "👨‍💻", "🏳️‍🌈", "☕️", "🇩🇪"] {
            XCTAssertTrue(Glyph.isEmoji(emoji), emoji)
        }
        for name in ["folder", "star.fill", "music.note", "1", "#", "a", ""] {
            XCTAssertFalse(Glyph.isEmoji(name), name)
        }
    }

    func testAnIconIsDrawnAsAnOutlineOrFilled() {
        XCTAssertEqual(Glyph.symbolName("star", filled: true), "star.fill")
        XCTAssertEqual(Glyph.symbolName("star", filled: false), "star")
        XCTAssertEqual(Glyph.symbolName("star.fill", filled: false), "star")
        XCTAssertEqual(Glyph.symbolName("star.fill", filled: true), "star.fill")
    }

    func testThePickersListsHoldNoRepeats() {
        XCTAssertEqual(Set(SpaceStyle.pickerSymbols).count, SpaceStyle.pickerSymbols.count)
        XCTAssertEqual(Set(SpaceStyle.pickerEmoji).count, SpaceStyle.pickerEmoji.count)
        XCTAssertTrue(SpaceStyle.pickerEmoji.allSatisfy(Glyph.isEmoji))
        XCTAssertFalse(SpaceStyle.pickerSymbols.contains(where: Glyph.isEmoji))
    }
}
