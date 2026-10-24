// swift-tools-version:5.9
import Foundation
import PackageDescription

// Archidea is a Swift package: `swift build` compiles it, incrementally, and Zed, VS Code or any editor with
// sourcekit-lsp reads this file for completion and navigation. No Xcode needed, only the Command Line Tools.
// The Makefile is the front door (`make help`): it builds with SwiftPM and packs the result into Archidea.app
// with scripts/bundle.sh, since SwiftPM makes no app bundles.
//
//   ArchideaCore      the model, the import merge, address parsing, update checks: Foundation only, unit-tested
//   Archidea          the app: AppKit around the engine
//   ArdiaCore         the engine's Objective-C API (vendor/engine), linked against Chromium Framework
//   ArchideaDockTile  the Dock's plug-in for the chosen icon; bundle.sh links it as a loadable bundle

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let engine = "\(root)/vendor/engine"
// Maintainers' scripted walkthroughs and self-checks, not published (see .gitignore).
let devHooks = FileManager.default.fileExists(atPath: "\(root)/Sources/Archidea/Dev")

let package = Package(
    name: "Archidea",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Archidea", targets: ["Archidea"]),
    ],
    targets: [
        .systemLibrary(name: "ArdiaCore", path: "vendor/engine"),
        .target(name: "ArchideaCore"),
        .executableTarget(
            name: "Archidea",
            dependencies: ["ArchideaCore", "ArdiaCore"],
            exclude: ["Import/Readers/LICENSE", "Import/Readers/NOTICE.md"],
            swiftSettings: [.define("DEBUG", .when(configuration: .debug))]
                + (devHooks ? [.define("DRIFT_DEV", .when(configuration: .debug))] : []),
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                // The framework sits next to the header while building and in Contents/Frameworks in the app.
                .unsafeFlags(["-F", engine, "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .target(name: "ArchideaDockTile"),
        .testTarget(name: "ArchideaCoreTests", dependencies: ["ArchideaCore"]),
    ]
)
