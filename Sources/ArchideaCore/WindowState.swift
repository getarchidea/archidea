import Foundation

/// One browser window's own view of the sidebar every window shares: the space it shows, the tab in front in each
/// space, whether its sidebar is hidden and where it sits. Kept with the sidebar, so the windows come back as they were.
public final class WindowState: Codable {
    public let id: UUID
    public var spaceID: UUID
    /// The tab in front in each space, by the space's ID.
    private var selected: [String: UUID]
    public var sidebarHidden: Bool
    /// Where the window was (`NSStringFromRect`); nil puts it where a new window goes.
    public var frame: String?

    public init(spaceID: UUID, sidebarHidden: Bool = false) {
        id = UUID()
        self.spaceID = spaceID
        selected = [:]
        self.sidebarHidden = sidebarHidden
    }

    /// The tab this window has in front in `space`. It may have gone since (closed in another window, archived):
    /// look it up in the space.
    public func selectedID(in space: Space) -> UUID? { selected[space.id.uuidString] }

    public func select(_ id: UUID?, in space: Space) { selected[space.id.uuidString] = id }

    private enum CodingKeys: String, CodingKey { case id, spaceID, selected, sidebarHidden, frame }

    /// Nothing here is worth failing over: a value that doesn't read takes its default (a space that doesn't exist
    /// is put right by `AppState.repair`).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        spaceID = (try? c.decodeIfPresent(UUID.self, forKey: .spaceID)) ?? UUID()
        selected = (try? c.decodeIfPresent([String: UUID].self, forKey: .selected)) ?? [:]
        sidebarHidden = (try? c.decodeIfPresent(Bool.self, forKey: .sidebarHidden)) ?? false
        frame = try? c.decodeIfPresent(String.self, forKey: .frame)
    }
}
