import Foundation

public enum CEFExtensionPreparationError: Error, Equatable, LocalizedError {
    case invalidExtensionID(String)
    /// The public key does not hash to the extension id.
    case publicKeyDoesNotMatchID
    /// The manifest already pins a `key`, and it is not this extension's.
    case manifestKeyDisagrees
    case unreadableManifest
    /// The manifest's `version` is not a Chrome version, or has no room for the shim's revision.
    case invalidVersion(String)
    /// A content revision outside 0 to 65535.
    case invalidRevision(Int)
    /// The source holds a trace of the WebKit compatibility layer under a name this code does not know.
    case unrecognisedWebKitLayer(String)
    /// The destination holds a copy with this very `version` but another worker path: two different shim and store versions added up to one.
    case versionCollision(String)
    case refused(CEFExtensionPolicy.Refusal)
    /// Chromium splits the `--load-extension` value on commas.
    case commaInDestination
    case destinationOverlapsSource
    case destinationNotAFolder
    case sourceNotAFolder
    case symlink(String)
    case specialFile(String)
    case tooDeep(String)
    /// The extension ships a file under a name the preparer writes.
    case nameTaken(String)
    case missingBackgroundFile(String)
    /// A WebKit compatibility worker whose original script cannot be read
    /// back out of it.
    case unreadableCompatibilityWorker
    /// A page in an encoding the shim's tag cannot be written into.
    case unsupportedHTMLEncoding(String)

    public var errorDescription: String? {
        switch self {
        case .invalidExtensionID(let id): return "\(id) is not an extension id."
        case .publicKeyDoesNotMatchID: return "The public key does not belong to this extension id."
        case .manifestKeyDisagrees: return "The extension's manifest pins a different key than the one it was published with."
        case .unreadableManifest: return "The extension's manifest.json could not be read."
        case .unrecognisedWebKitLayer(let path): return "The extension holds an unknown compatibility file or tag (\(path))."
        case .invalidRevision(let revision): return "The content revision \(revision) is not between 0 and 65535."
        case .versionCollision(let version): return "The existing Chromium copy already has version \(version) with different content."
        case .invalidVersion(let version): return "The extension's version (\(version)) cannot be extended with the browser's revision."
        case .refused(let refusal): return refusal.message
        case .commaInDestination: return "The folder for the Chromium copy has a comma in its path."
        case .destinationOverlapsSource: return "The folder for the Chromium copy and the extension's folder contain each other."
        case .destinationNotAFolder: return "Something that is not a folder is where the Chromium copy goes."
        case .sourceNotAFolder: return "The extension's folder is not a folder."
        case .symlink(let path): return "The extension holds a link (\(path)), which is not copied."
        case .specialFile(let path): return "The extension holds a file that is not a plain file or folder (\(path))."
        case .tooDeep(let path): return "The extension's folders go too deep (\(path))."
        case .nameTaken(let name): return "The extension already has a file named \(name)."
        case .missingBackgroundFile(let path): return "The extension's background script \(path) is not in the package."
        case .unreadableCompatibilityWorker: return "The extension's compatibility worker could not be read."
        case .unsupportedHTMLEncoding(let path): return "The page \(path) is not in an encoding the browser can add its script to."
        }
    }
}

/// The `version` and worker path of the copy a new one replaces.
public struct PreviousCEFCopy: Equatable, Sendable {
    public let version: String
    public let workerFile: String?
    public init(version: String, workerFile: String?) {
        self.version = version
        self.workerFile = workerFile
    }
}

/// What `CEFExtensionPreparer.prepare` made.
public struct PreparedCEFExtension: Equatable, Sendable {
    public let destination: URL
    public let extensionID: String
    public let shimVersion: Int
    /// Paths, relative to `destination`, of the pages that got the shim.
    public let pages: [String]
    /// The worker path the manifest now names, beside the original worker; nil
    /// when the extension has no service worker.
    public let workerFile: String?
    /// The manifest `version` of the copy.
    public let version: String
    /// Random per copy. The shim sends it with every request to the app.
    public let token: String
    /// The folder held the WebKit compatibility layer, which was taken out.
    public let removedWebKitLayer: Bool
}

/// Makes the copy of an extension that Chromium loads.
///
/// Never point `destination` at a folder Chromium has loaded: it writes into
/// a loaded folder and needs it unmodified for the whole session, so each
/// prepare goes to a new, versioned destination.
///
/// The copy is the extension's own code plus the CEF shim and nothing else:
/// the store `key` in the manifest (so the extension keeps its Web Store id,
/// and with it its storage and its published origin), the shim as the first
/// code of the worker and of every page, a host permission for the shim's
/// channel, and a content-security-policy that lets the shim use it. The
/// WebKit side writes its own layer into the unpacked folder; the Chromium
/// side never loads that, so any trace of it found in the source is taken out.
public enum CEFExtensionPreparer {
    /// What `ChromeExtensionCompatibility` writes into a folder for WebKit,
    /// which this code only recognises and removes. A trace under any other
    /// `__browser_` name is refused (`unrecognisedWebKitLayer`) rather than
    /// carried into the Chromium copy.
    enum WebKitLayer {
        static let shimFile = "__browser_chrome_compat.js"
        static let workerFile = "__browser_background.js"
        static let pageTag = "<script src=\"/\(shimFile)\"></script>"
    }

    private static let maximumDepth = 64
    private static let manifestName = "manifest.json"

    /// The `key` a manifest pins, decoded; nil when there is none or it is
    /// not base64. An unpacked developer folder that pins one has no
    /// package to take a key from, and this is where its key comes from.
    public static func pinnedPublicKey(inManifestAt folder: URL) -> Data? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(manifestName)),
              let manifest = try? CEFExtensionPolicy.parseManifest(data),
              let key = manifest["key"] as? String
        else { return nil }
        return decodeKey(key)
    }

    /// Prepares the unpacked extension in `source` as `destination`.
    ///
    /// `previous` is the copy this one replaces; a new copy whose `version` equals
    /// it with another worker path is refused (`versionCollision`), since the
    /// profile would keep the old worker's registration. `token` is random unless
    /// given. Nothing is written into `source`. The copy is built in a staging folder
    /// beside `destination` and moved into place last, so a run that fails
    /// leaves what was there before, and a second run on the same input
    /// writes the same bytes.
    @discardableResult
    public static func prepare(source: URL, extensionID: String, publicKey: Data, destination: URL, contentRevision: Int? = nil,
                                previous: PreviousCEFCopy? = nil, token: String? = nil) throws -> PreparedCEFExtension {
        guard ChromeExtensionID.isValid(extensionID) else { throw CEFExtensionPreparationError.invalidExtensionID(extensionID) }
        guard ChromeExtensionID.from(publicKey: publicKey) == extensionID else { throw CEFExtensionPreparationError.publicKeyDoesNotMatchID }
        guard !destination.path.contains(",") else { throw CEFExtensionPreparationError.commaInDestination }

        let files = FileManager.default
        let sourceRoot = source.resolvingSymlinksInPath().standardizedFileURL
        guard (try? files.attributesOfItem(atPath: sourceRoot.path)[.type] as? FileAttributeType) == .typeDirectory else {
            throw CEFExtensionPreparationError.sourceNotAFolder
        }
        // The destination is used exactly as given, links and all: the caller
        // chose the path Chromium will be told about. Only the overlap check
        // compares resolved paths.
        let target = destination
        let resolvedTarget = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent(destination.lastPathComponent).path
        if resolvedTarget == sourceRoot.path || resolvedTarget.hasPrefix(sourceRoot.path + "/") || sourceRoot.path.hasPrefix(resolvedTarget + "/") {
            throw CEFExtensionPreparationError.destinationOverlapsSource
        }
        if let type = (try? files.attributesOfItem(atPath: target.path))?[.type] as? FileAttributeType, type != .typeDirectory {
            throw CEFExtensionPreparationError.destinationNotAFolder
        }

        let entries = try walk(sourceRoot).filter { !isChromiumWritten($0.path) }
        guard entries.contains(where: { $0.path == manifestName && !$0.isDirectory }) else { throw CEFExtensionPreparationError.unreadableManifest }
        let manifestData = try Data(contentsOf: sourceRoot.appendingPathComponent(manifestName))
        guard var manifest = try? CEFExtensionPolicy.parseManifest(manifestData) else { throw CEFExtensionPreparationError.unreadableManifest }
        if let refusal = CEFExtensionPolicy.evaluate(manifest: manifest).refusal { throw CEFExtensionPreparationError.refused(refusal) }

        let present = Set(entries.map(\.path))
        let storeVersion = manifest["version"] as? String ?? ""
        if let contentRevision, !(0...65535).contains(contentRevision) { throw CEFExtensionPreparationError.invalidRevision(contentRevision) }
        if present.contains(CEFExtensionShim.fileName) { throw CEFExtensionPreparationError.nameTaken(CEFExtensionShim.fileName) }
        for path in present where !path.contains("/") && path.hasPrefix("__browser_")
            && path != WebKitLayer.shimFile && path != WebKitLayer.workerFile {
            throw CEFExtensionPreparationError.unrecognisedWebKitLayer(path)
        }

        try setKey(publicKey, in: &manifest)
        let versions = try setVersion(in: &manifest, revision: contentRevision)
        let removedLayer = present.contains(WebKitLayer.shimFile) || present.contains(WebKitLayer.workerFile)
        let workerFile = try wrapBackground(in: &manifest, sourceRoot: sourceRoot, present: present,
                                            storeVersion: storeVersion, revision: contentRevision)
        if let previous, previous.version == versions.prepared, previous.workerFile != workerFile?.path {
            throw CEFExtensionPreparationError.versionCollision(versions.prepared)
        }
        let copyToken = token ?? Self.randomToken()
        removeFileAccess(from: &manifest)
        addBridgePermission(to: &manifest)
        allowBridgeInContentSecurityPolicy(of: &manifest)

        let parent = target.deletingLastPathComponent()
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".preparing-\(extensionID)-\(UUID().uuidString)", isDirectory: true)
        do {
            try files.createDirectory(at: staging, withIntermediateDirectories: false)
            var pages: [String] = []
            for entry in entries {
                let from = sourceRoot.appendingPathComponent(entry.path)
                let to = staging.appendingPathComponent(entry.path)
                if entry.isDirectory {
                    try files.createDirectory(at: to, withIntermediateDirectories: true)
                    continue
                }
                if entry.path == manifestName || entry.path == WebKitLayer.shimFile || entry.path == WebKitLayer.workerFile { continue }
                let ext = (entry.path as NSString).pathExtension.lowercased()
                if ext == "html" || ext == "htm" {
                    let page = try shimmingPage(Data(contentsOf: from), path: entry.path, extensionID: extensionID)
                    try page.write(to: to)
                    pages.append(entry.path)
                } else {
                    try files.copyItem(at: from, to: to)
                }
            }

            try Data(CEFExtensionShim.fileContents(storeVersion: versions.store, preparedVersion: versions.prepared, addedVersionName: versions.addedVersionName, token: copyToken).utf8)
                .write(to: staging.appendingPathComponent(CEFExtensionShim.fileName))
            if let workerFile {
                try Data(workerSource(wrapping: workerFile.original, module: workerFile.isModule).utf8)
                    .write(to: staging.appendingPathComponent(workerFile.path))
            }
            let manifestOut = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try manifestOut.write(to: staging.appendingPathComponent(manifestName))

            try replace(target, with: staging)
            return PreparedCEFExtension(
                destination: target, extensionID: extensionID, shimVersion: CEFExtensionShim.version,
                pages: pages.sorted(), workerFile: workerFile?.path, version: versions.prepared, token: copyToken,
                removedWebKitLayer: removedLayer
            )
        } catch {
            try? files.removeItem(at: staging)
            throw error
        }
    }

    static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<2).map { _ in String(UInt64.random(in: .min ... .max, using: &generator), radix: 16) }
            .map { String(repeating: "0", count: 16 - $0.count) + $0 }.joined()
    }

    /// Staging and set-aside folders a crash or quit left behind.
    public static func removeLeftovers(in directory: URL) {
        let files = FileManager.default
        guard let names = try? files.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(".preparing-") || name.hasPrefix(".replaced-") {
            try? files.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: - Reading the source

    struct Entry: Equatable {
        let path: String
        let isDirectory: Bool
    }

    /// Every file and folder under `root`, parents before children. A link
    /// or any file that is not plain stops the whole run: nothing is read
    /// through a link, so nothing outside `root` can come into the copy.
    static func walk(_ root: URL) throws -> [Entry] {
        var out: [Entry] = []
        func visit(_ relative: String, depth: Int) throws {
            guard depth <= maximumDepth else { throw CEFExtensionPreparationError.tooDeep(relative) }
            let directory = relative.isEmpty ? root : root.appendingPathComponent(relative)
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            for name in names {
                let path = relative.isEmpty ? name : relative + "/" + name
                let type = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)[.type] as? FileAttributeType
                switch type {
                case .typeRegular:
                    out.append(Entry(path: path, isDirectory: false))
                case .typeDirectory:
                    out.append(Entry(path: path, isDirectory: true))
                    try visit(path, depth: depth + 1)
                case .typeSymbolicLink:
                    throw CEFExtensionPreparationError.symlink(path)
                default:
                    throw CEFExtensionPreparationError.specialFile(path)
                }
            }
        }
        try visit("", depth: 0)
        return out
    }

    // MARK: - Manifest

    /// Chromium writes `_metadata/` (content verification data for the
    /// package's own files) into a folder it loads. It describes the
    /// source's files, not the prepared ones, and a name starting with an
    /// underscore is reserved, so it is never carried into the copy.
    static func isChromiumWritten(_ path: String) -> Bool {
        path == "_metadata" || path.hasPrefix("_metadata/")
    }

    static func decodeKey(_ text: String) -> Data? {
        let compact = text.components(separatedBy: .whitespacesAndNewlines).joined()
        guard let data = Data(base64Encoded: compact), !data.isEmpty else { return nil }
        return data
    }

    static func setKey(_ publicKey: Data, in manifest: inout [String: Any]) throws {
        if let existing = manifest["key"] {
            guard let text = existing as? String, decodeKey(text) == publicKey else { throw CEFExtensionPreparationError.manifestKeyDisagrees }
        }
        manifest["key"] = publicKey.base64EncodedString()
    }

    /// The shim revision rides in `version`, so that a new shim always
    /// changes the manifest version together with the worker's file name (see
    /// `CEFExtensionShim.workerPath`). The store's own version
    /// stays readable in `version_name` unless the manifest has one.
    static func setVersion(in manifest: inout [String: Any], revision: Int?) throws -> VersionRecord {
        let stored = manifest["version"] as? String ?? ""
        guard let prepared = CEFExtensionShim.preparedVersion(storeVersion: stored, shimVersion: CEFExtensionShim.version, revision: revision) else {
            throw CEFExtensionPreparationError.invalidVersion(stored)
        }
        let added = manifest["version_name"] == nil
        if added { manifest["version_name"] = stored }
        manifest["version"] = prepared
        return VersionRecord(store: stored, prepared: prepared, addedVersionName: added)
    }

    struct VersionRecord {
        let store: String
        let prepared: String
        let addedVersionName: Bool
    }

    struct Worker {
        let original: String
        let isModule: Bool
        /// Where the wrapper goes, relative to the extension's root.
        let path: String
    }

    /// Points the manifest's worker at the wrapper and drops the WebKit
    /// layer's entries from it. Returns the worker the wrapper must load.
    static func wrapBackground(in manifest: inout [String: Any], sourceRoot: URL, present: Set<String>,
                               storeVersion: String, revision: Int?) throws -> Worker? {
        guard var background = manifest["background"] as? [String: Any] else { return nil }
        var worker: Worker?
        if let named = background["service_worker"] as? String {
            var original = normalizedPath(named)
            if original == WebKitLayer.workerFile {
                original = try originalWorker(inCompatibilityWorkerAt: sourceRoot.appendingPathComponent(WebKitLayer.workerFile))
            }
            guard ZipArchive.isSafeRelativePath(original), present.contains(original) else {
                throw CEFExtensionPreparationError.missingBackgroundFile(original)
            }
            let path = CEFExtensionShim.workerPath(original: original, storeVersion: storeVersion, revision: revision)
            if present.contains(path) { throw CEFExtensionPreparationError.nameTaken(path) }
            worker = Worker(original: original, isModule: (background["type"] as? String) == "module", path: path)
            background["service_worker"] = path
        }
        if var scripts = background["scripts"] as? [Any], (scripts.first as? String) == WebKitLayer.shimFile {
            scripts.removeFirst()
            background["scripts"] = scripts
        }
        manifest["background"] = background
        return worker
    }

    /// The script the WebKit layer's worker wraps: the last quoted path in
    /// its `importScripts(...)` or `import "...";` line.
    static func originalWorker(inCompatibilityWorkerAt url: URL) throws -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw CEFExtensionPreparationError.unreadableCompatibilityWorker }
        let quoted = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        var paths: [String] = []
        for line in text.split(whereSeparator: \.isNewline) where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
            let line = String(line)
            for match in quoted.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                guard let range = Range(match.range, in: line),
                      let decoded = try? JSONDecoder().decode(String.self, from: Data(line[range].utf8))
                else { throw CEFExtensionPreparationError.unreadableCompatibilityWorker }
                paths.append(decoded)
            }
        }
        guard paths.count == 2, paths[0] == "/" + WebKitLayer.shimFile else { throw CEFExtensionPreparationError.unreadableCompatibilityWorker }
        return normalizedPath(paths[1])
    }

    /// A manifest path as Chrome reads it: relative to the extension's root, with
    /// any leading `/` or `./` dropped.
    static func normalizedPath(_ path: String) -> String {
        var rest = Substring(path)
        while true {
            if rest.hasPrefix("/") { rest = rest.dropFirst() } else if rest.hasPrefix("./") { rest = rest.dropFirst(2) } else { break }
        }
        return String(rest)
    }

    /// Nothing the prepared manifest asks for covers `file:` (see
    /// `CEFExtensionPolicy.webPatterns`). A content script, or a
    /// web-accessible-resources entry, left with no pattern is removed, since
    /// Chromium refuses an empty list.
    static func removeFileAccess(from manifest: inout [String: Any]) {
        func rewritten(_ value: Any?) -> [String]? {
            (value as? [Any]).map { CEFExtensionPolicy.webPatterns($0.compactMap { $0 as? String }) }
        }
        for key in ["host_permissions", "optional_host_permissions"] {
            if let patterns = rewritten(manifest[key]) { manifest[key] = patterns }
        }
        if let scripts = manifest["content_scripts"] as? [Any] {
            var kept: [Any] = []
            for case var script as [String: Any] in scripts {
                guard let patterns = rewritten(script["matches"]) else { kept.append(script); continue }
                if patterns.isEmpty { continue }
                script["matches"] = patterns
                kept.append(script)
            }
            manifest["content_scripts"] = kept
        }
        if let resources = manifest["web_accessible_resources"] as? [Any] {
            var kept: [Any] = []
            for case var entry as [String: Any] in resources {
                if let patterns = rewritten(entry["matches"]) {
                    if patterns.isEmpty {
                        entry["matches"] = nil
                        if (entry["extension_ids"] as? [Any])?.isEmpty ?? true { continue }
                    } else {
                        entry["matches"] = patterns
                    }
                }
                kept.append(entry)
            }
            manifest["web_accessible_resources"] = kept
        }
        if var connectable = manifest["externally_connectable"] as? [String: Any], let patterns = rewritten(connectable["matches"]) {
            connectable["matches"] = patterns.isEmpty ? nil : patterns
            manifest["externally_connectable"] = connectable
        }
    }

    static func addBridgePermission(to manifest: inout [String: Any]) {
        var hosts = (manifest["host_permissions"] as? [Any]) ?? []
        if !hosts.contains(where: { ($0 as? String) == CEFExtensionShim.bridgeHostPermission }) {
            hosts.append(CEFExtensionShim.bridgeHostPermission)
        }
        manifest["host_permissions"] = hosts
    }

    /// The default extension-page policy restricts no fetch. One the
    /// extension wrote may, and then the shim's request to the bridge is
    /// refused before it leaves the page.
    static func allowBridgeInContentSecurityPolicy(of manifest: inout [String: Any]) {
        guard var policy = manifest["content_security_policy"] as? [String: Any],
              let pages = policy["extension_pages"] as? String
        else { return }
        policy["extension_pages"] = allowingBridge(inPolicy: pages)
        manifest["content_security_policy"] = policy
    }

    static func allowingBridge(inPolicy policy: String) -> String {
        let origin = CEFExtensionShim.bridgeOrigin
        var directives = policy.split(separator: ";").map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }.filter { !$0.isEmpty }
        func sources(of name: String) -> [String]? {
            directives.first { $0[0].lowercased() == name }.map { Array($0.dropFirst()) }
        }
        let granting = { (list: [String]) -> Bool in list.contains(origin) || list.contains("*") || list.contains("https:") }
        if let connect = sources(of: "connect-src") {
            if !granting(connect) {
                let kept = connect.filter { $0.lowercased() != "'none'" }
                directives = directives.map { $0[0].lowercased() == "connect-src" ? ["connect-src"] + kept + [origin] : $0 }
            }
        } else if let fallback = sources(of: "default-src"), !granting(fallback) {
            directives.append(["connect-src"] + fallback.filter { $0.lowercased() != "'none'" } + [origin])
        }
        return directives.map { $0.joined(separator: " ") }.joined(separator: "; ") + ";"
    }

    // MARK: - Worker

    static func workerSource(wrapping original: String, module: Bool) -> String {
        let shim = jsString("/" + CEFExtensionShim.fileName)
        let wrapped = jsString("/" + original)
        let header = "// Written by the browser: runs the CEF shim ahead of the extension's own worker.\n"
        if module { return header + "import \(shim);\nimport \(wrapped);\n" }
        return header + "importScripts(\(shim), \(wrapped));\n"
    }

    static func jsString(_ text: String) -> String {
        let data = (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
    }

    // MARK: - Pages

    static func pageTag(extensionID: String) -> String {
        "<script src=\"chrome-extension://\(extensionID)/\(CEFExtensionShim.fileName)\"></script>"
    }

    /// `html` with the WebKit layer's tag taken out and the shim's tag put
    /// first in the document's `<head>` (or the nearest place the parser
    /// still takes it as the first script): after `<head>`, else after
    /// `<html>`, else after the doctype, else at the start. A page with no
    /// script of its own gets it too. Absolute, so a `<base>` cannot move it.
    static func shimmingPage(_ html: Data, path: String, extensionID: String) throws -> Data {
        var bytes = [UInt8](html)
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) || bytes.prefix(1024).contains(0) {
            throw CEFExtensionPreparationError.unsupportedHTMLEncoding(path)
        }
        bytes = replacing(Array(WebKitLayer.pageTag.utf8), with: [], in: bytes)
        if referencesWebKitLayerScript(bytes, extensionID: extensionID) { throw CEFExtensionPreparationError.unrecognisedWebKitLayer(path) }
        let tag = Array(pageTag(extensionID: extensionID).utf8)
        if find(bytes, tag, from: 0) != nil { return Data(bytes) }
        let at = insertionPoint(in: bytes)
        return Data(bytes[..<at] + tag + bytes[at...])
    }

    /// A `src` attribute that names a file the WebKit layer writes, under a name
    /// this code does not know. Prose or a script string that mentions the
    /// prefix is not one.
    static func referencesWebKitLayerScript(_ bytes: [UInt8], extensionID: String) -> Bool {
        let lowered = bytes.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
        let targets = ["/__browser_", "chrome-extension://\(extensionID)/__browser_"]
        for quote in ["\"", "'", ""] {
            for target in targets where find(lowered, Array(("src=" + quote + target).utf8), from: 0) != nil { return true }
        }
        return false
    }

    /// Elements whose content is text, not markup: a `<head` inside one is not a tag.
    private static let rawTextElements = ["script", "style", "template", "textarea", "title", "xmp", "iframe", "noembed", "noframes", "plaintext"]

    /// Walks the markup tag by tag, so that attribute values, comments and the
    /// text of scripts are never taken for tags.
    static func insertionPoint(in bytes: [UInt8]) -> Int {
        let start = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        var htmlEnd: Int?
        var doctypeEnd: Int?
        var i = start
        scan: while i < bytes.count {
            guard bytes[i] == UInt8(ascii: "<") else { i += 1; continue }
            if matches(bytes, at: i, Array("<!--".utf8)) {
                // `<!-->` and `<!--->` are complete, empty comments.
                if matches(bytes, at: i, Array("<!-->".utf8)) { i += 5; continue }
                if matches(bytes, at: i, Array("<!--->".utf8)) { i += 6; continue }
                guard let end = find(bytes, Array("-->".utf8), from: i + 4) else { break }
                i = end + 3
                continue
            }
            if matches(bytes, at: i, Array("<!doctype".utf8), ignoringCase: true) {
                guard let end = tagEnd(bytes, from: i) else { break }
                if doctypeEnd == nil { doctypeEnd = end }
                i = end
                continue
            }
            let nameStart = i + 1
            guard nameStart < bytes.count else { break }
            let first = bytes[nameStart]
            let isLetter = (first >= 65 && first <= 90) || (first >= 97 && first <= 122)
            if !isLetter && first != UInt8(ascii: "/") {
                // `<!x>`, `<?x>` and a stray `<`: markup declarations end at `>`.
                if first == UInt8(ascii: "!") || first == UInt8(ascii: "?") {
                    guard let end = tagEnd(bytes, from: i) else { break }
                    i = end
                } else {
                    i += 1
                }
                continue
            }
            var nameEnd = first == UInt8(ascii: "/") ? nameStart + 1 : nameStart
            while nameEnd < bytes.count, !hasTagBoundary(bytes, at: nameEnd) { nameEnd += 1 }
            let name = String(decoding: bytes[(first == UInt8(ascii: "/") ? nameStart + 1 : nameStart)..<nameEnd], as: UTF8.self).lowercased()
            guard let end = tagEnd(bytes, from: i) else { break }
            if first == UInt8(ascii: "/") { i = end; continue }
            switch name {
            case "head":
                return end
            case "html":
                if htmlEnd == nil { htmlEnd = end }
            case "body", "frameset":
                break scan
            default:
                if rawTextElements.contains(name) {
                    let close = Array("</\(name)".utf8)
                    var j = end
                    var found: Int?
                    while j + close.count <= bytes.count {
                        if matches(bytes, at: j, close, ignoringCase: true), hasTagBoundary(bytes, at: j + close.count) { found = j; break }
                        j += 1
                    }
                    guard let found else { break scan }
                    i = found
                    continue
                }
            }
            i = end
        }
        return htmlEnd ?? doctypeEnd ?? start
    }

    /// The index after the `>` that closes the tag opened at `index`, with
    /// quoted attribute values stepped over.
    static func tagEnd(_ bytes: [UInt8], from index: Int) -> Int? {
        var i = index + 1
        var quote: UInt8?
        while i < bytes.count {
            let byte = bytes[i]
            if let open = quote {
                if byte == open { quote = nil }
            } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                quote = byte
            } else if byte == UInt8(ascii: ">") {
                return i + 1
            }
            i += 1
        }
        return nil
    }

    static func hasTagBoundary(_ bytes: [UInt8], at index: Int) -> Bool {
        guard index < bytes.count else { return true }
        return [UInt8(ascii: ">"), UInt8(ascii: "/"), UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"), 0x0C].contains(bytes[index])
    }

    private static func matches(_ bytes: [UInt8], at index: Int, _ pattern: [UInt8], ignoringCase: Bool = false) -> Bool {
        guard index + pattern.count <= bytes.count else { return false }
        for (offset, expected) in pattern.enumerated() {
            var byte = bytes[index + offset]
            if ignoringCase, byte >= UInt8(ascii: "A"), byte <= UInt8(ascii: "Z") { byte += 32 }
            if byte != expected { return false }
        }
        return true
    }

    private static func find(_ bytes: [UInt8], _ pattern: [UInt8], from start: Int) -> Int? {
        guard !pattern.isEmpty else { return nil }
        var i = start
        while i + pattern.count <= bytes.count {
            if matches(bytes, at: i, pattern) { return i }
            i += 1
        }
        return nil
    }

    private static func replacing(_ pattern: [UInt8], with replacement: [UInt8], in bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            if matches(bytes, at: i, pattern) {
                out += replacement
                i += pattern.count
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }

    // MARK: - Putting the copy in place

    /// The old copy is kept aside until the new one is in place, so a failed
    /// move leaves it as it was.
    static func replace(_ destination: URL, with staged: URL) throws {
        let files = FileManager.default
        let aside = destination.deletingLastPathComponent()
            .appendingPathComponent(".replaced-\(destination.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
        let hadOld = files.fileExists(atPath: destination.path)
        if hadOld { try files.moveItem(at: destination, to: aside) }
        do {
            try files.moveItem(at: staged, to: destination)
        } catch {
            if hadOld { try? files.moveItem(at: aside, to: destination) }
            throw error
        }
        if hadOld { try? files.removeItem(at: aside) }
    }
}
