// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AutofillCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AutofillCore", targets: ["AutofillCore"]),
    ],
    dependencies: [
        .package(path: "../BrowserCore"),
    ],
    targets: [
        .target(name: "AutofillCore", dependencies: [.product(name: "BrowserCore", package: "BrowserCore")]),
        .testTarget(name: "AutofillCoreTests", dependencies: ["AutofillCore"]),
    ]
)
