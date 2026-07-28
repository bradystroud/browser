// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BlockListCore",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "BlockListCore", targets: ["BlockListCore"]),
    ],
    targets: [
        .target(name: "BlockListCore"),
        .testTarget(name: "BlockListCoreTests", dependencies: ["BlockListCore"]),
    ]
)
