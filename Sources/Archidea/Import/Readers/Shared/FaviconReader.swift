import Foundation

/// Site icons another browser already keeps, so imported tabs, bookmarks and history show theirs before they are
/// visited again. Two kinds come back: the icon of each page asked for by URL, and one icon per site (keyed by the
/// site's root, `https://host/`) that stands in for every page of it.
public enum FaviconReader {
  public struct Icon: Sendable {
    public let page: String
    public let icon: String
    /// PNG for Chromium; Firefox can hold ICO or SVG too, which the caller converts.
    public let data: Data
  }

  /// A guard against huge profiles: sites past this many keep no icon from the import.
  static let siteLimit = 6000

  public static func chromium(profile dir: URL, pages: Set<String>, cancellation: Cancellation = .init()) throws -> [Icon] {
    let file = dir.appendingPathComponent("Favicons")
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    let db = try SQLiteSnapshot(copying: file)
    guard db.tableExists("icon_mapping"), db.tableExists("favicon_bitmaps") else { return [] }
    // icon_type 1 is the page's favicon proper (not a touch icon); the bitmap closest to 32 px wins.
    let sql = """
      SELECT m.page_url, f.url, b.image_data, b.width FROM icon_mapping m
      JOIN favicons f ON f.id = m.icon_id JOIN favicon_bitmaps b ON b.icon_id = f.id
      WHERE f.icon_type = 1 AND length(b.image_data) > 0
      """
    var picker = Picker(pages: pages)
    var count = 0
    try db.query(sql) { row in
      count += 1
      if count % 512 == 0 { try cancellation.check() }
      guard let page = row.text(0), let icon = row.text(1), let data = row.blob(2) else { return true }
      picker.offer(page: page, icon: icon, data: data, width: Int(row.int(3)))
      return true
    }
    return picker.icons
  }

  public static func firefox(profile dir: URL, pages: Set<String>, cancellation: Cancellation = .init()) throws -> [Icon] {
    let file = dir.appendingPathComponent("favicons.sqlite")
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    let db = try SQLiteSnapshot(copying: file)
    guard db.tableExists("moz_icons"), db.tableExists("moz_pages_w_icons") else { return [] }
    let sql = """
      SELECT p.page_url, i.icon_url, i.data, i.width FROM moz_icons_to_pages ip
      JOIN moz_pages_w_icons p ON p.id = ip.page_id JOIN moz_icons i ON i.id = ip.icon_id
      WHERE length(i.data) > 0
      """
    var picker = Picker(pages: pages)
    var count = 0
    try db.query(sql) { row in
      count += 1
      if count % 512 == 0 { try cancellation.check() }
      guard let page = row.text(0), let icon = row.text(1), let data = row.blob(2) else { return true }
      picker.offer(page: page, icon: icon, data: data, width: Int(row.int(3)))
      return true
    }
    return picker.icons
  }

  /// Keeps the best bitmap per wanted page and, per site, the icon most of its pages use (a page reached through
  /// a sign-in can carry the sign-in service's icon; one such page mustn't give the whole site that icon).
  private struct Picker {
    let pages: Set<String>
    private var byPage: [String: (icon: Icon, width: Int)] = [:]
    /// Per site, per icon URL: how many pages use it, and its best bitmap.
    private var bySite: [String: [String: (pages: Int, icon: Icon, width: Int)]] = [:]

    init(pages: Set<String>) { self.pages = pages }

    /// 32 px is what the sidebar draws at 2x; bigger is fine, smaller looks soft.
    private static func score(_ width: Int) -> Int { width >= 32 ? 1000 - (width - 32) : width }

    mutating func offer(page: String, icon: String, data: Data, width: Int) {
      guard URL.isWebURL(page), let url = URL(string: page), let scheme = url.scheme, let host = url.host else { return }
      if pages.contains(page), (byPage[page].map { Self.score(width) > Self.score($0.width) } ?? true) {
        byPage[page] = (Icon(page: page, icon: icon, data: data), width)
      }
      let site = "\(scheme)://\(host)/"
      guard bySite[site] != nil || bySite.count < FaviconReader.siteLimit else { return }
      var icons = bySite[site, default: [:]]
      if var known = icons[icon] {
        known.pages += 1
        if Self.score(width) > Self.score(known.width) { (known.icon, known.width) = (Icon(page: site, icon: icon, data: data), width) }
        icons[icon] = known
      } else {
        icons[icon] = (1, Icon(page: site, icon: icon, data: data), width)
      }
      bySite[site] = icons
    }

    var icons: [Icon] {
      byPage.values.map(\.icon) + bySite.values.compactMap { icons in
        icons.values.max { ($0.pages, Self.score($0.width)) < ($1.pages, Self.score($1.width)) }?.icon
      }
    }
  }
}
