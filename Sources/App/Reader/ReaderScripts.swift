import Foundation

/// Loads and caches the vendored Readability.js / Readability-readerable.js
/// source (see those files' own header comments for provenance/license)
/// from the app bundle's Contents/Resources/Reader/ directory, copied there
/// by Sources/App/CMakeLists.txt's POST_BUILD step.
enum ReaderScripts {
    static let readabilityJS: String = load("Readability")
    static let readerableJS: String = load("Readability-readerable")

    private static func load(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js", subdirectory: "Reader"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            NSLog("Browser: failed to load vendored Reader script %@.js from the app bundle", name)
            return ""
        }
        return contents
    }
}
