// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BrowserCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BrowserCore", targets: ["BrowserCore"])
    ],
    targets: [
        .target(
            name: "BrowserCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "BrowserCoreTests",
            dependencies: ["BrowserCore"]
        )
    ]
)
