// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BrowserCLIProtocol",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "BrowserCLIProtocol", targets: ["BrowserCLIProtocol"]),
    ],
    targets: [
        .target(name: "BrowserCLIProtocol"),
        .testTarget(name: "BrowserCLIProtocolTests", dependencies: ["BrowserCLIProtocol"]),
    ]
)
