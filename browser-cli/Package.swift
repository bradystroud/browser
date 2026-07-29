// swift-tools-version: 6.0
// Standalone SwiftPM package for the `browser` CLI (browser-82d) -- a
// separate executable target, deliberately kept out of the Xcode/CMake app
// build entirely (Sources/App/CMakeLists.txt never references this
// directory), so nothing about the CLI can ever break the .app build. Build
// with `swift build -c release`; scripts/build.sh does this too and copies
// the resulting binary into Browser.app/Contents/Resources/bin/browser --
// see that script and docs/ai-tasks/browser-cli-notes.md for how Brady puts
// it on his PATH.
//
// Depends locally on this same repo's other standalone packages rather than
// duplicating their logic: RoutingCore (real RuleMatcher/RoutingRule, for
// `route-test`), Packages/BrowserCore (real Database/HistoryStore/
// BookmarkStore, for `history`/`bookmarks`), and Packages/BrowserCLIProtocol
// (the socket wire format shared with the app-side listener,
// Sources/App/CLI/CLIServer.swift). Unlike the CMake app target -- where
// linking a SwiftPM package into an Xcode-generator target is "its own can
// of worms" (see other packages' own doc comments) -- a plain SwiftPM
// executable can just depend on them normally.
import PackageDescription

let package = Package(
    name: "browser-cli",
    // .v13, not .v12 -- matches Packages/BrowserCore's own platform floor
    // (its SQLite wrapper needs it), which this package depends on.
    platforms: [.macOS(.v13)],
    products: [
        // Named "browser" (not "BrowserCLI") deliberately -- this is the
        // literal binary name Brady runs and puts on his PATH.
        .executable(name: "browser", targets: ["BrowserCLI"]),
    ],
    dependencies: [
        .package(path: "../RoutingCore"),
        .package(path: "../Packages/BrowserCore"),
        .package(path: "../Packages/BrowserCLIProtocol"),
    ],
    targets: [
        .executableTarget(
            name: "BrowserCLI",
            dependencies: ["RoutingCore", "BrowserCore", "BrowserCLIProtocol"]
        ),
        .testTarget(
            name: "BrowserCLITests",
            dependencies: ["BrowserCLI"]
        ),
    ]
)
