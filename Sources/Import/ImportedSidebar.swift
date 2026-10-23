import Foundation

/// A space as another browser had it, before it becomes one of Drift's.
struct ImportedSpace {
    var name: String
    var colorHex: String?
    var symbol: String?
    var pinned: [ImportedNode]
    var tabs: [ImportedNode]
}

indirect enum ImportedNode {
    case tab(url: String, title: String)
    case folder(title: String, symbol: String?, children: [ImportedNode], expanded: Bool)
}
