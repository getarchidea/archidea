import XCTest
@testable import ArchideaCore

final class URLInputTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLInput.engine = .google
    }

    func testAddressesStayAsTyped() {
        XCTAssertEqual(URLInput.resolve("https://example.com/a?b=c"), "https://example.com/a?b=c")
        XCTAssertEqual(URLInput.resolve("about:blank"), "about:blank")
        XCTAssertEqual(URLInput.resolve("chrome://settings"), "chrome://settings")
    }

    func testBareHostsGetAScheme() {
        XCTAssertEqual(URLInput.resolve("example.com"), "https://example.com")
        XCTAssertEqual(URLInput.resolve("  example.com/path  "), "https://example.com/path")
        XCTAssertEqual(URLInput.resolve("localhost:3000"), "http://localhost:3000")
        XCTAssertEqual(URLInput.resolve("app.localhost"), "http://app.localhost")
        XCTAssertEqual(URLInput.resolve("192.168.1.10:8080/x"), "http://192.168.1.10:8080/x")
    }

    func testEverythingElseIsASearch() {
        XCTAssertEqual(URLInput.resolve("swift concurrency"), "https://www.google.com/search?q=swift%20concurrency")
        XCTAssertEqual(URLInput.resolve("a&b=c"), "https://www.google.com/search?q=a%26b%3Dc")
        XCTAssertEqual(URLInput.resolve("999.1.1.1"), "https://www.google.com/search?q=999.1.1.1")
        XCTAssertTrue(URLInput.isSearch("hello"))
        XCTAssertFalse(URLInput.isSearch("example.com"))
    }

    func testTheChosenEngineIsUsed() {
        URLInput.engine = .duckduckgo
        XCTAssertEqual(URLInput.resolve("privacy"), "https://duckduckgo.com/?q=privacy")
    }

    func testNothingTypedIsABlankPage() {
        XCTAssertEqual(URLInput.resolve("   "), "about:blank")
    }
}
