import Foundation

/// A space as another browser had it, before it becomes one of Drift's.
public struct ImportedSpace {
    public var name: String
    public var colorHex: String?
    public var symbol: String?
    public var pinned: [ImportedNode]
    public var tabs: [ImportedNode]

    public init(name: String, colorHex: String?, symbol: String?, pinned: [ImportedNode], tabs: [ImportedNode]) {
        self.name = name
        self.colorHex = colorHex
        self.symbol = symbol
        self.pinned = pinned
        self.tabs = tabs
    }
}

public indirect enum ImportedNode {
    case tab(url: String, title: String)
    case folder(title: String, symbol: String?, children: [ImportedNode], expanded: Bool)
}
