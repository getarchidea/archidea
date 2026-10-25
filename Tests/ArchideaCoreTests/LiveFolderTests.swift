import XCTest
@testable import ArchideaCore

final class LiveFolderTests: XCTestCase {
    private let rss = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom" xmlns:dc="http://purl.org/dc/elements/1.1/">
      <channel>
        <title>A Blog</title>
        <link>https://blog.example/</link>
        <atom:link href="https://blog.example/feed" rel="self" type="application/rss+xml"/>
        <image><title>Logo</title><url>https://blog.example/logo.png</url><link>https://blog.example/</link></image>
        <item>
          <title><![CDATA[Second & newest]]></title>
          <link>https://blog.example/2</link>
          <guid isPermaLink="false">post-2</guid>
          <dc:creator>Someone</dc:creator>
        </item>
        <item>
          <title>First</title>
          <link>https://blog.example/1</link>
        </item>
      </channel>
    </rss>
    """

    private let atom = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom" xmlns:yt="http://www.youtube.com/xml/schemas/2015"
          xmlns:media="http://search.yahoo.com/mrss/">
      <title>A Channel</title>
      <link rel="self" href="https://videos.example/feeds/videos.xml"/>
      <link rel="alternate" href="https://videos.example/channel"/>
      <entry>
        <id>yt:video:abc</id>
        <title>A video</title>
        <link rel="alternate" href="https://videos.example/watch?v=abc"/>
        <media:group><media:title>Not this title</media:title></media:group>
      </entry>
      <entry>
        <id>tag:videos.example,2026:2</id>
        <title>Relative</title>
        <link href="/watch?v=def"/>
      </entry>
    </feed>
    """

    private let rdf = """
    <?xml version="1.0"?>
    <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/">
      <channel rdf:about="https://old.example/"><title>Old School</title><link>https://old.example/</link></channel>
      <item rdf:about="https://old.example/a"><title>A</title><link>https://old.example/a</link></item>
    </rdf:RDF>
    """

    func testRSS() throws {
        let feed = try XCTUnwrap(FeedParser.parse(Data(rss.utf8)))
        XCTAssertEqual(feed.title, "A Blog")
        XCTAssertEqual(feed.site, "https://blog.example/")
        XCTAssertEqual(feed.entries, [FeedEntry(id: "post-2", title: "Second & newest", url: "https://blog.example/2"),
                                      FeedEntry(id: "https://blog.example/1", title: "First", url: "https://blog.example/1")])
    }

    func testAtomLeavesOtherVocabulariesAloneAndReadsRelativeLinks() throws {
        let feed = try XCTUnwrap(FeedParser.parse(Data(atom.utf8), base: URL(string: "https://videos.example/feeds/videos.xml")))
        XCTAssertEqual(feed.title, "A Channel")
        XCTAssertEqual(feed.site, "https://videos.example/channel")
        XCTAssertEqual(feed.entries.map(\.title), ["A video", "Relative"])
        XCTAssertEqual(feed.entries.map(\.id), ["yt:video:abc", "tag:videos.example,2026:2"])
        XCTAssertEqual(feed.entries.last?.url, "https://videos.example/watch?v=def")
    }

    func testRDF() throws {
        let feed = try XCTUnwrap(FeedParser.parse(Data(rdf.utf8)))
        XCTAssertEqual(feed.title, "Old School")
        XCTAssertEqual(feed.entries, [FeedEntry(id: "https://old.example/a", title: "A", url: "https://old.example/a")])
    }

    func testAPageIsNoFeed() {
        XCTAssertNil(FeedParser.parse(Data("<html><head><title>Hi</title></head><body></body></html>".utf8)))
        XCTAssertNil(FeedParser.parse(Data("not xml at all".utf8)))
    }

    func testFeedLinksInAPage() {
        let html = """
        <html><head>
        <link rel="stylesheet" href="/s.css">
        <link rel="alternate" type="application/rss+xml" title="Posts" href="/feed.xml">
        <LINK REL='alternate' TYPE='application/atom+xml' HREF='https://other.example/atom?a=1&amp;b=2'>
        <link rel="alternate" hreflang="de" href="/de/">
        <link rel="alternate" type="application/rss+xml" href="/feed.xml">
        </head></html>
        """
        let links = FeedParser.feedLinks(inHTML: html, base: URL(string: "https://blog.example/post/1")!)
        XCTAssertEqual(links.map(\.absoluteString), ["https://blog.example/feed.xml", "https://other.example/atom?a=1&b=2"])
    }

    func testGuessesAreAtTheSiteRoot() {
        let guesses = FeedParser.guesses(for: URL(string: "https://blog.example:8443/post/1?x=1")!)
        XCTAssertEqual(guesses.first?.absoluteString, "https://blog.example:8443/feed")
    }

    // MARK: the folder

    private func liveFolder() -> SidebarItem {
        let folder = SidebarItem(folder: "News")
        folder.feed = LiveFeed(url: "https://blog.example/feed")
        return folder
    }

    private func entries(_ ids: [Int]) -> [FeedEntry] {
        ids.map { FeedEntry(id: "e\($0)", title: "Post \($0)", url: "https://blog.example/\($0)") }
    }

    func testTheFirstFillIsReadAndWhatComesAfterIsNew() {
        let folder = liveFolder()
        folder.refresh(with: entries([2, 1]), markRead: true)
        XCTAssertEqual(folder.children.map(\.url), ["https://blog.example/2", "https://blog.example/1"])
        XCTAssertEqual(folder.unreadCount, 0)
        XCTAssertEqual(folder.children.first?.pinnedURL, "https://blog.example/2", "a live folder's tabs are pins")
        let added = folder.refresh(with: entries([4, 3, 2, 1]))
        XCTAssertEqual(added.map(\.entryID), ["e4", "e3"])
        XCTAssertEqual(folder.children.map(\.entryID), ["e4", "e3", "e2", "e1"])
        XCTAssertEqual(folder.unreadCount, 2)
        XCTAssertTrue(folder.refresh(with: entries([4, 3, 2, 1])).isEmpty, "nothing comes in twice")
    }

    func testOnlyTheLatestStayAndTheOnesKeptStayToo() {
        let folder = liveFolder()
        folder.refresh(with: entries([3, 2, 1]), limit: 3, markRead: true)
        let open = folder.children[2]
        folder.refresh(with: entries([5, 4, 3, 2, 1]), limit: 3) { $0 === open }
        XCTAssertEqual(folder.children.map(\.entryID), ["e5", "e4", "e1"])
        XCTAssertTrue(folder.refresh(with: entries([5, 4, 3, 2, 1]), limit: 3).isEmpty, "what went as old doesn't come back")
    }

    func testTabsPutInByHandStay() {
        let folder = liveFolder()
        let mine = SidebarItem(tab: "https://mine.example")
        folder.children = [mine]
        folder.refresh(with: entries([3, 2, 1]), limit: 2)
        XCTAssertTrue(folder.children.contains { $0 === mine })
        XCTAssertEqual(folder.children.filter { $0.entryID != nil }.count, 2)
    }

    func testATabTakenOutDoesntComeBackButOneMovedWithinStays() {
        let space = Space(name: "Work", symbol: "briefcase", colorHex: "#7C8CF8")
        let folder = liveFolder()
        space.pinned = [folder]
        folder.refresh(with: entries([3, 2, 1]))
        space.move(folder.children[2], to: .folder(folder), at: 0)
        XCTAssertEqual(folder.feed?.dismissed, [])
        let taken = folder.children[1]
        space.remove(taken)
        XCTAssertEqual(folder.feed?.dismissed, [taken.entryID ?? ""])
        XCTAssertTrue(folder.refresh(with: entries([3, 2, 1])).isEmpty)
    }

    func testAnOpenedTabIsReadAndUnreadIsntWrittenForEveryTab() throws {
        let folder = liveFolder()
        folder.refresh(with: entries([1]))
        let tab = try XCTUnwrap(folder.children.first)
        XCTAssertTrue(tab.isUnread)
        tab.isUnread = false
        let plain = String(decoding: try JSONEncoder().encode(SidebarItem(tab: "https://a.example")), as: UTF8.self)
        XCTAssertFalse(plain.contains("unread"))
    }

    func testALiveFolderRoundTrips() throws {
        let folder = liveFolder()
        folder.refresh(with: entries([2, 1]))
        folder.feed?.etag = "\"abc\""
        let back = try JSONDecoder().decode(SidebarItem.self, from: JSONEncoder().encode(folder))
        XCTAssertTrue(back.isLive)
        XCTAssertEqual(back.feed, folder.feed)
        XCTAssertEqual(back.children.map(\.entryID), ["e2", "e1"])
        XCTAssertEqual(back.unreadCount, 2)
    }
}
