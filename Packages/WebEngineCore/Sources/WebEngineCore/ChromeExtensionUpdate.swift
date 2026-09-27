import Foundation

/// A Chrome extension version: one to four dot-separated integers, each
/// 0-65535, compared numerically part by part with missing parts as zero --
/// so "1.10" is newer than "1.9", and "2" equals "2.0.0.0". Anything else is
/// not a valid manifest version, and Chrome refuses it too.
public struct ChromeExtensionVersion: Comparable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 5, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part), value <= 65535,
                  // Chrome rejects a leading zero ("1.01").
                  part == "0" || !part.hasPrefix("0")
            else { return nil }
            numbers.append(value)
        }
        components = numbers
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    private var padded: [Int] { components + Array(repeating: 0, count: 4 - components.count) }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.padded.lexicographicallyPrecedes(rhs.padded)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.padded == rhs.padded
    }
}

/// The update service's answer to an `updatecheck` request (Omaha protocol,
/// XML): per `<app appid="…">`, one `<updatecheck status="…" …>`.
///
/// Parsed as XML rather than matched as text. A text match for the first
/// `version="…"` finds the XML declaration's `version="1.0"`, and
/// `status="ok"` also appears on `<app>` whether or not there is an update --
/// read that way, every extension looks out of date every day and is
/// downloaded and reloaded again for nothing.
public struct ChromeExtensionUpdateCheck: Equatable {
    public let appID: String
    public let status: String
    public let version: String?
    public let codebase: String?

    /// A newer version than `installed`, if the service offers one. A
    /// version that does not parse, or is not newer, is no update.
    public func availableUpdate(over installed: String) -> ChromeExtensionVersion? {
        guard status == "ok", let version, let offered = ChromeExtensionVersion(version) else { return nil }
        guard let current = ChromeExtensionVersion(installed) else { return offered }
        return offered > current ? offered : nil
    }

    public static func parse(_ xml: Data) -> [ChromeExtensionUpdateCheck] {
        let delegate = ResponseParser()
        let parser = XMLParser(data: xml)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.results
    }

    private final class ResponseParser: NSObject, XMLParserDelegate {
        var results: [ChromeExtensionUpdateCheck] = []
        private var currentApp: String?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "app":
                currentApp = attributes["appid"]
            case "updatecheck":
                guard let app = currentApp else { return }
                results.append(ChromeExtensionUpdateCheck(
                    appID: app,
                    status: attributes["status"] ?? "",
                    version: attributes["version"],
                    codebase: attributes["codebase"]))
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "app" { currentApp = nil }
        }
    }
}
