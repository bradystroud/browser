// swift-tools-version: 6.0
// Standalone package for the pointer-gesture logic behind two-finger swipe
// navigation and middle-click autoscroll: thresholds, axis locking, the arm
// and flick rules, the indicator's geometry and the autoscroll speed curve.
// Pure Swift/Foundation, no AppKit, so `swift test` covers it in isolation.
// The app target (Sources/App/CMakeLists.txt) compiles these same source
// files directly into the Browser executable -- one copy of the logic, two
// ways to build it, the same pattern as every other package here.
import PackageDescription

let package = Package(
    name: "GestureCore",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "GestureCore", targets: ["GestureCore"]),
    ],
    targets: [
        .target(name: "GestureCore"),
        .testTarget(name: "GestureCoreTests", dependencies: ["GestureCore"]),
    ]
)
