// swift-tools-version:6.0
// Standalone package for the link-routing rule model + matcher: pure Swift,
// Foundation-only, no AppKit/CEF dependency, so it can be unit-tested with a
// plain `swift test` independent of the CMake/Xcode app build. The app target
// (Sources/App/CMakeLists.txt) compiles these same source files directly into
// the Browser executable rather than linking this package, so there is only
// one copy of the logic; this package exists to make that logic runnable and
// testable in isolation. See docs/ai-tasks/m2-routing-notes.md for the
// `swift test` command.
import PackageDescription

let package = Package(
    name: "RoutingCore",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "RoutingCore", targets: ["RoutingCore"]),
    ],
    targets: [
        .target(name: "RoutingCore"),
        .testTarget(name: "RoutingCoreTests", dependencies: ["RoutingCore"]),
    ]
)
