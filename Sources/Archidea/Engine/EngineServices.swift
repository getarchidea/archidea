import ArdiaCore
import Foundation

extension ArdiaCoreProfile {
    /// Chrome's services for this profile, typed.
    var services: EngineServices { EngineServices(profile: self) }
}

/// Chrome's services the app uses, as typed calls: each function's arguments and reply, written down once here.
/// Replies come on the main queue.
struct EngineServices {
    let profile: ArdiaCoreProfile

    typealias Completion<Value> = (Result<Value, EngineFailure>) -> Void

    // MARK: history

    /// A page in history, as the address bar's suggestions read it.
    struct Visit: Decodable {
        let url: String
        let title: String
        let visits: Int
        /// Milliseconds since 1970, the latest first.
        let times: [Double]

        private enum CodingKeys: String, CodingKey { case url = "u", title = "t", visits = "n", times = "v" }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            url = try c.decode(String.self, forKey: .url)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            visits = try c.decodeIfPresent(Int.self, forKey: .visits) ?? 1
            times = try c.decodeIfPresent([Double].self, forKey: .times) ?? []
        }
    }

    /// The whole history, most recent first: at most `maxURLs` pages with up to `maxVisits` visit times each.
    func history(maxURLs: Int, maxVisits: Int, completion: @escaping Completion<[Visit]>) {
        struct Args: Encodable { let maxUrls: Int, maxVisits: Int }
        struct Reply: Decodable { let entries: [Lossy<Visit>]? }
        EngineCall.request(.historyQuery, profile: profile, args: Args(maxUrls: maxURLs, maxVisits: maxVisits)) { (result: Result<Reply, EngineFailure>) in
            completion(result.map { ($0.entries ?? []).compactMap(\.value) })
        }
    }

    /// A page brought over from another browser's history.
    struct ImportedVisit: Encodable {
        let url: String
        let title: String
        let visits: Int
        /// When it was last visited, as the reader gives it.
        let lastVisit: Double

        private enum CodingKeys: String, CodingKey { case url = "u", title = "t", visits = "n", lastVisit = "l" }
    }

    func importHistory(_ rows: [ImportedVisit], timeout: TimeInterval, completion: @escaping Completion<EngineDone>) {
        struct Args: Encodable { let rows: [ImportedVisit] }
        EngineCall.request(.historyImport, profile: profile, args: Args(rows: rows), timeout: timeout, completion: completion)
    }

    // MARK: bookmarks

    /// One step of building the bookmarks: adding a folder or a bookmark under `parent` ("bar", "other" or an `id`
    /// added before).
    struct BookmarkOp: Encodable {
        enum Kind: String, Encodable { case folder = "f", url = "u" }

        let op = "add"
        let id: String
        let kind: Kind
        let title: String
        let url: String?
        /// Milliseconds since 1970.
        let added: Double
        let parent: String

        private enum CodingKeys: String, CodingKey { case op, id, kind = "k", title = "t", url = "u", added = "a", parent }
    }

    func applyBookmarks(_ ops: [BookmarkOp], timeout: TimeInterval, completion: @escaping Completion<EngineDone>) {
        struct Args: Encodable { let ops: [BookmarkOp] }
        EngineCall.request(.bookmarksApply, profile: profile, args: Args(ops: ops), timeout: timeout, completion: completion)
    }

    // MARK: favicons

    /// The PNG icons the engine has for `pages`, by page; a page with none isn't in the result.
    func favicons(pages: [String], size: Int, completion: @escaping Completion<[String: Data]>) {
        struct Args: Encodable { let pages: [String], size: Int }
        struct Icon: Decodable { let png: String? }
        struct Reply: Decodable { let pages: [String: Lossy<Icon>]? }
        EngineCall.request(.faviconsGet, profile: profile, args: Args(pages: pages, size: size)) { (result: Result<Reply, EngineFailure>) in
            completion(result.map { reply in
                (reply.pages ?? [:]).compactMapValues { $0.value?.png.flatMap { Data(base64Encoded: $0) } }
            })
        }
    }

    /// Stores `png` as the icon of `page`, whose site's icon is at `icon`.
    func setFavicon(page: String, icon: String, png: Data, timeout: TimeInterval, completion: @escaping Completion<EngineDone>) {
        struct Args: Encodable { let page: String, icon: String, png: String }
        EngineCall.request(.faviconsSet, profile: profile, args: Args(page: page, icon: icon, png: png.base64EncodedString()),
                           timeout: timeout, completion: completion)
    }

    // MARK: downloads

    /// The profile's downloads. Asking also starts the engine's `downloads.changed` and `downloads.removed` events.
    func downloads(completion: @escaping Completion<[Downloads.Item]>) {
        struct Reply: Decodable { let downloads: [Lossy<Downloads.Item>]? }
        EngineCall.request(.downloadsList, profile: profile, args: [String: String]()) { (result: Result<Reply, EngineFailure>) in
            completion(result.map { ($0.downloads ?? []).compactMap(\.value) })
        }
    }

    enum DownloadAction {
        case pause, resume, cancel
        /// Keep a download Chrome flagged as dangerous or insecure.
        case keep
        /// Take it off the list; the file stays.
        case remove

        fileprivate var function: EngineFunction {
            switch self {
            case .pause: .downloadsPause
            case .resume: .downloadsResume
            case .cancel: .downloadsCancel
            case .keep: .downloadsKeep
            case .remove: .downloadsRemove
            }
        }
    }

    func download(_ id: String, _ action: DownloadAction, completion: @escaping Completion<EngineDone>) {
        EngineCall.request(action.function, profile: profile, args: ["id": id], completion: completion)
    }

    // MARK: sites

    /// What a site may do, by permission type ("geolocation", "sound"…): "allow", "block" or "ask".
    func siteSettings(origin: String, completion: @escaping Completion<[String: String]>) {
        struct Setting: Decodable { let value: String? }
        struct Reply: Decodable { let settings: [String: Lossy<Setting>]? }
        EngineCall.request(.siteSettingsGet, profile: profile, args: ["origin": origin]) { (result: Result<Reply, EngineFailure>) in
            completion(result.map { reply in (reply.settings ?? [:]).mapValues { $0.value?.value ?? "ask" } })
        }
    }

    func setSiteSetting(origin: String, type: String, value: String, completion: @escaping Completion<EngineDone>) {
        EngineCall.request(.siteSettingsSet, profile: profile, args: ["origin": origin, "type": type, "value": value],
                           completion: completion)
    }

    /// Clears everything the site stored: cookies, storage, cache.
    func clearSiteData(origin: String, completion: @escaping Completion<EngineDone>) {
        EngineCall.request(.siteDataClear, profile: profile, args: ["origin": origin], completion: completion)
    }

    // MARK: secrets (import)

    /// Saves a password. `json` is `{"origin", "username", "password"}`, NUL-terminated; see `EngineCall.requestSecret`.
    func addPassword(json: UnsafeRawBufferPointer, timeout: TimeInterval, completion: @escaping Completion<EngineDone>) {
        EngineCall.requestSecret(.passwordsAdd, profile: profile, json: json, timeout: timeout, completion: completion)
    }

    /// Sets a batch of cookies (`CookieWire`); the reply counts those that went in.
    func importCookies(json: UnsafeRawBufferPointer, timeout: TimeInterval, completion: @escaping Completion<Int>) {
        struct Reply: Decodable { let imported: Int? }
        EngineCall.requestSecret(.cookiesImport, profile: profile, json: json, timeout: timeout) { (result: Result<Reply, EngineFailure>) in
            completion(result.map { $0.imported ?? 0 })
        }
    }
}

/// An element of a list that reads as `Value`, or nil when it doesn't: one odd entry doesn't cost the whole list.
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
