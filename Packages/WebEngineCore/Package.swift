// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WebEngineCore",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "WebEngineCore", targets: ["WebEngineCore"]),
    ],
    targets: [
        .target(name: "WebEngineCore"),
        .testTarget(name: "WebEngineCoreTests", dependencies: ["WebEngineCore"]),
    ]
)
