// swift-tools-version: 6.0
// Standalone package for the persisted-session model (browser-n2j): the
// `session.json` shape, and the stack of recently closed tabs and windows
// behind ⇧⌘T. Pure Swift/Foundation, no AppKit, so `swift test` runs it in
// isolation. The app target (Sources/App/CMakeLists.txt) compiles these
// same source files directly into the Browser executable rather than
// linking this package -- one copy of the logic, two ways to build it, the
// same pattern RoutingCore and BrowserCore use.
//
// The file I/O stays in the app (SessionStore, ClosedItemStore): it depends
// on CommandLineArgs for the `--profiles-root`-scoped directory, which is
// AppKit-adjacent app configuration, not model logic.
import PackageDescription

let package = Package(
    name: "SessionCore",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "SessionCore", targets: ["SessionCore"]),
    ],
    targets: [
        .target(name: "SessionCore"),
        .testTarget(name: "SessionCoreTests", dependencies: ["SessionCore"]),
    ]
)
