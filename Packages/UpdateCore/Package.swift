// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UpdateCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "UpdateCore", targets: ["UpdateCore"]),
        .executable(name: "appcast-tool", targets: ["appcast-tool"])
    ],
    targets: [
        .target(name: "UpdateCore"),
        .executableTarget(name: "appcast-tool", dependencies: ["UpdateCore"]),
        .testTarget(name: "UpdateCoreTests", dependencies: ["UpdateCore"])
    ]
)
