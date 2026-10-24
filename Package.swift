// swift-tools-version:5.9
import PackageDescription

// The app is built by build.sh (swiftc against the prebuilt Chromium engine). This package holds the parts that need
// neither AppKit nor the engine (the sidebar's model, the import merge, the address bar's parsing, update checks)
// so they build and are tested on their own: `swift test`.
let package = Package(
    name: "Archidea",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "ArchideaCore",
            path: "Sources",
            sources: [
                "App/L10n.swift",
                "App/Minisign.swift",
                "Import/ImportedSidebar.swift",
                "Model/ImportMerge.swift",
                "Model/Model.swift",
                "Model/SpaceStyle.swift",
                "Model/URLInput.swift",
            ]
        ),
        .testTarget(name: "ArchideaCoreTests", dependencies: ["ArchideaCore"], path: "Tests/ArchideaCoreTests"),
    ]
)
