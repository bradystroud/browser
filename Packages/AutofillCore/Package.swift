// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AutofillCore",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "AutofillCore", targets: ["AutofillCore"]),
    ],
    targets: [
        .target(name: "AutofillCore"),
        .testTarget(name: "AutofillCoreTests", dependencies: ["AutofillCore"]),
    ]
)
