// swift-tools-version: 5.9
import PackageDescription

// The self-update logic, shared by the app and its install helper.
// Sources/App/CMakeLists.txt compiles the UpdateCore sources straight into
// the Browser executable; scripts/bundle-update-agent.sh builds the helper
// from this package and puts it at Browser.app/Contents/MacOS/BrowserUpdateAgent.
let package = Package(
    name: "UpdateCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "UpdateCore", targets: ["UpdateCore"]),
        .executable(name: "BrowserUpdateAgent", targets: ["BrowserUpdateAgent"])
    ],
    targets: [
        .target(name: "UpdateCore"),
        .executableTarget(name: "BrowserUpdateAgent", dependencies: ["UpdateCore"]),
        .testTarget(name: "UpdateCoreTests", dependencies: ["UpdateCore"])
    ]
)
