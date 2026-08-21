// swift-tools-version: 6.0
// Standalone package for the omnibox's search logic (browser-0du): deciding
// whether typed text is a URL or a search query, turning a query into a
// search URL for the chosen engine, parsing an engine's suggestion response,
// and Quick Website Search. Pure Swift/Foundation, no AppKit and no engine
// surface, so `swift test` runs it in isolation. The app target
// (Sources/App/CMakeLists.txt) compiles these same source files directly
// into the Browser executable rather than linking this package -- one copy
// of the logic, two ways to build it, the same pattern RoutingCore and
// BrowserCore use.
import PackageDescription

let package = Package(
    name: "SearchCore",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "SearchCore", targets: ["SearchCore"]),
    ],
    targets: [
        .target(name: "SearchCore"),
        .testTarget(name: "SearchCoreTests", dependencies: ["SearchCore"]),
    ]
)
