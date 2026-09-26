// swift-tools-version: 5.9
import PackageDescription

// Runs the app's real WebKit engine adapter inside XCTest, against a real
// WKWebView. The WebKitAdapter target holds no logic of its own: its
// Engine/, PageZoom.swift, EmailFieldDetectionScript.swift and WebEngineCore/
// entries are symlinks to the very
// files Sources/App/CMakeLists.txt compiles into Browser.app, so a new
// Engine/WebKit*.swift file is picked up here with no change to this package.
// The only real source in the target is AppShims.swift, which stands in for
// the few app types the adapter names but the tests never exercise.
let package = Package(
    name: "WebKitEngineTests",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "WebKitAdapter",
            exclude: [
                // CEF-backed; needs the Obj-C++ bridge and libcef.
                "Engine/CEFEngineAdapter.swift",
            ],
            linkerSettings: [.linkedFramework("WebKit"), .linkedFramework("AppKit")]
        ),
        .testTarget(
            name: "WebKitAdapterTests",
            dependencies: ["WebKitAdapter"]
        ),
    ]
)
