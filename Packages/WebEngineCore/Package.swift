// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WebEngineCore",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "WebEngineCore", targets: ["WebEngineCore"]),
    ],
    dependencies: [
        // Tests only: the bundled starter block list is the real input the
        // WebKit adapter feeds ContentRuleListBuilder.
        .package(path: "../BlockListCore"),
    ],
    targets: [
        .target(name: "WebEngineCore"),
        .testTarget(
            name: "WebEngineCoreTests",
            dependencies: ["WebEngineCore", .product(name: "BlockListCore", package: "BlockListCore")],
            // fixture-hello.crx: a real CRX3, packed by Chrome's own
            // --pack-extension from a two-file extension with a throwaway key.
            resources: [.copy("Fixtures")]
        ),
    ]
)
