import CryptoKit
import Foundation

// The decisions the CEF extension runtime makes before Chromium starts and
// while it runs, kept free of files and of the engine so they can be tested:
// which installed extensions a profile runs in CEF tabs, which prepared
// copies to keep, make or delete, and which bridge requests to act on.

/// What the app found on disk for one installed extension, read before the
/// planner decides about it.
public struct CEFExtensionSourceFacts: Equatable, Sendable {
    /// The folder the copy is made from: the store folder the app unpacked,
    /// or the developer's own folder.
    public var folder: String
    public var folderExists: Bool
    /// The source manifest's own `key`, decoded. The only key an unpacked
    /// developer folder can have.
    public var manifestKey: Data?
    public var refusal: CEFExtensionPolicy.Refusal?
    /// A digest of the source tree (paths, sizes, modification dates). Set
    /// for an unpacked folder only, which can change between launches with
    /// no version change; a store folder changes only with its version.
    public var treeStamp: String?
    /// Everything Chromium grants the extension at load
    /// (`CEFExtensionPolicy.Verdict.grants`).
    public var chromiumGrants: [String]
    /// The source manifest's `version`, which the prepared version extends.
    public var sourceVersion: String?

    public init(folder: String, folderExists: Bool, manifestKey: Data? = nil,
                refusal: CEFExtensionPolicy.Refusal? = nil, treeStamp: String? = nil, chromiumGrants: [String] = [],
                sourceVersion: String? = nil) {
        self.sourceVersion = sourceVersion
        self.folder = folder
        self.folderExists = folderExists
        self.manifestKey = manifestKey
        self.refusal = refusal
        self.treeStamp = treeStamp
        self.chromiumGrants = chromiumGrants
    }
}

/// One extension the profile runs in CEF tabs, and what its prepared copy is
/// made from.
public struct CEFExtensionBuild: Equatable, Sendable {
    public let id: String
    public let sourceFolder: String
    public let publicKey: Data
    /// Equal fingerprints mean an existing prepared copy is still right.
    public let fingerprint: String
    /// The source manifest's `version`.
    public var sourceVersion: String? = nil

    /// A developer's folder, which can change with no version change.
    public var isUnpacked: Bool { fingerprint.hasPrefix("unpacked|") }
}

public enum CEFExtensionDecision: Equatable, Sendable {
    case run(CEFExtensionBuild)
    case disabled
    /// A store install from before the app kept the store key. One download
    /// of the package gives it.
    case waitingForKey
    /// Why it does not run in CEF tabs, in words the UI can show.
    case unavailable(String)
    /// Chromium would grant it more than the user agreed to. The value is
    /// everything Chromium would grant, for the approval sheet.
    case needsApproval([String])

    public var build: CEFExtensionBuild? {
        if case .run(let build) = self { return build }
        return nil
    }
}

public enum CEFExtensionPlanner {
    public static let unpackedWithoutKey =
        "Its folder's manifest.json pins no \"key\", so it would get a different id in Chromium tabs."
    public static let missingFolder = "Its files are missing."
    public static let keyMismatch = "Its key does not belong to its id."
    public static let declinedReason =
        "Chromium tabs would give it a permission you declined for it, so it does not run there."

    /// - Parameters:
    ///   - approved: grants the user approved for Chromium tabs (the
    ///     approval sheet, or an install or update consent that carried the
    ///     Chromium note), beside the record's own `grants`.
    ///   - declined: grants the user declined; never covered.
    public static func decide(_ record: InstalledWebExtension, facts: CEFExtensionSourceFacts,
                              approved: [String] = [], declined: [String] = [],
                              shimVersion: Int = CEFExtensionShim.version) -> CEFExtensionDecision {
        guard record.enabled else { return .disabled }
        guard facts.folderExists else { return .unavailable(missingFolder) }
        if let refusal = facts.refusal { return .unavailable(refusal.message) }
        let key: Data
        switch record.source {
        case .webStore:
            guard let stored = record.publicKey.flatMap({ Data(base64Encoded: $0) }), !stored.isEmpty else { return .waitingForKey }
            key = stored
        case .unpacked:
            guard let pinned = facts.manifestKey, !pinned.isEmpty else { return .unavailable(unpackedWithoutKey) }
            key = pinned
        }
        guard ChromeExtensionID.from(publicKey: key) == record.id else { return .unavailable(keyMismatch) }
        // A declined grant cannot be approved here: the extension stays out.
        if facts.chromiumGrants.contains(where: Set(declined).contains) { return .unavailable(declinedReason) }
        if !isCovered(facts.chromiumGrants, agreed: record.grants + approved, declined: declined) {
            return .needsApproval(facts.chromiumGrants)
        }
        let keyDigest = SHA256.hash(data: key).prefix(8).map { String(format: "%02x", $0) }.joined()
        let fingerprint: String
        switch record.source {
        case .webStore:
            fingerprint = "store|\(record.version)|shim\(shimVersion)|key\(keyDigest)"
        case .unpacked:
            fingerprint = "unpacked|\(facts.folder)|\(facts.treeStamp ?? "-")|shim\(shimVersion)|key\(keyDigest)"
        }
        return .run(CEFExtensionBuild(id: record.id, sourceFolder: facts.folder, publicKey: key, fingerprint: fingerprint,
                                      sourceVersion: facts.sourceVersion))
    }

    /// Whether the user agreed to everything Chromium grants: nothing beyond
    /// what was agreed (access to every site covers any one site), and
    /// nothing that was declined.
    ///
    /// Access to all web sites (`*://*/*`) does not cover `<all_urls>` or a
    /// `file:` pattern: those reach files on this Mac too.
    public static func isCovered(_ grants: [String], agreed: [String], declined: [String]) -> Bool {
        let declinedSet = Set(declined)
        let agreedNow = Set(agreed).subtracting(declinedSet)
        return grants.allSatisfy { grant in
            guard !declinedSet.contains(grant) else { return false }
            if agreedNow.contains(grant) { return true }
            guard grant.hasPrefix("host:") else { return false }
            if agreedNow.contains("host:<all_urls>") { return true }
            let pattern = grant.dropFirst(5)
            let reachesFiles = pattern == "<all_urls>" || pattern.lowercased().hasPrefix("file:")
            return !reachesFiles && agreedNow.contains("host:*://*/*")
        }
    }
}

/// An install list as read from disk, telling "nothing installed" from "no
/// list" and "a list this build cannot read". Only a list that was read may
/// lead to deleting anything.
public enum CEFExtensionInstallList {
    public enum Read: Equatable {
        case absent
        case unreadable(String)
        /// `declined` holds each record's `declinedGrants`, when the file
        /// has them.
        case list(InstalledWebExtensionList, declined: [String: [String]])

        public var list: InstalledWebExtensionList? {
            if case .list(let list, _) = self { return list }
            return nil
        }
    }

    public static func read(_ url: URL) -> Read {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url) else { return .unreadable("it could not be read") }
        return parse(data)
    }

    public static func parse(_ data: Data) -> Read {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let list = try decoder.decode(InstalledWebExtensionList.self, from: data)
            var declined: [String: [String]] = [:]
            if let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let records = raw["extensions"] as? [[String: Any]] {
                for record in records {
                    if let id = record["id"] as? String, let grants = record["declinedGrants"] as? [String] { declined[id] = grants }
                }
            }
            return .list(list, declined: declined)
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }
}

/// A profile's record of the copies prepared for Chromium: kept next to them
/// as `state.json`.
public struct CEFExtensionProfileState: Codable, Equatable, Sendable {
    public struct Copy: Codable, Equatable, Sendable {
        /// The copy's folder name under the extension's own folder.
        public var folder: String
        public var fingerprint: String
        /// The content revision the copy was prepared with (unpacked sources
        /// only): it names the worker and the manifest version, so an edit
        /// that keeps the version still gets a new worker.
        public var revision: Int?
        /// The random value the copy's shim sends with every request; a
        /// request without it is not this copy's.
        public var requestToken: String?

        public init(folder: String, fingerprint: String, revision: Int? = nil, requestToken: String? = nil) {
            self.folder = folder
            self.fingerprint = fingerprint
            self.revision = revision
            self.requestToken = requestToken
        }
    }

    public var current: [String: Copy]
    /// Every extension that has been on this profile's list at a launch, so
    /// Chromium may hold data for it in the profile. Its data is deleted when
    /// it leaves the install list.
    public var known: [String]
    /// The lifecycle events confirmed per extension id. Nil in a state file
    /// written before the app kept them, or rebuilt after one could not be
    /// read: an extension `known` then ran before, and gets no `install`.
    public var lifecycle: [String: CEFExtensionLifecycle.Record]?
    /// The last content revision used per unpacked extension id. Never
    /// dropped, also when the id leaves the install list: a folder removed
    /// and added again must not get an old worker name and version back.
    public var revisions: [String: Int]
    /// Grants the user approved for Chromium tabs, per extension id.
    public var approvedGrants: [String: [String]]
    /// Extensions whose Chromium data is still to be deleted; cleared once
    /// the deletes succeeded, so a crash in between deletes it next time.
    public var pendingDeletion: [String]

    public init(current: [String: Copy] = [:], known: [String] = [], lifecycle: [String: CEFExtensionLifecycle.Record]? = [:],
                revisions: [String: Int] = [:], approvedGrants: [String: [String]] = [:], pendingDeletion: [String] = []) {
        self.current = current
        self.known = known
        self.lifecycle = lifecycle
        self.revisions = revisions
        self.approvedGrants = approvedGrants
        self.pendingDeletion = pendingDeletion
    }

    private enum CodingKeys: String, CodingKey { case current, known, lifecycle, revisions, approvedGrants, pendingDeletion }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        current = try container.decode([String: Copy].self, forKey: .current)
        known = try container.decode([String].self, forKey: .known)
        lifecycle = try container.decodeIfPresent([String: CEFExtensionLifecycle.Record].self, forKey: .lifecycle)
        revisions = try container.decodeIfPresent([String: Int].self, forKey: .revisions) ?? [:]
        approvedGrants = try container.decodeIfPresent([String: [String]].self, forKey: .approvedGrants) ?? [:]
        pendingDeletion = try container.decodeIfPresent([String].self, forKey: .pendingDeletion) ?? []
    }

    public enum Read: Equatable {
        case absent
        case unreadable
        case state(CEFExtensionProfileState)
    }

    public static func read(from url: URL) -> Read {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(CEFExtensionProfileState.self, from: data) else { return .unreadable }
        return .state(state)
    }

    public static func load(from url: URL) -> CEFExtensionProfileState {
        if case .state(let state) = read(from: url) { return state }
        return CEFExtensionProfileState()
    }

    /// What can be known when `state.json` could not be read: the ids with
    /// copy folders ran before (so: no `install`, data kept until they leave
    /// the list), and each one's highest revision from its copies' worker
    /// names, so a revision never goes back.
    public static func rebuilt(foldersOnDisk: [String: Set<String>], workerFiles: [String: [String]]) -> CEFExtensionProfileState {
        var revisions: [String: Int] = [:]
        for (id, files) in workerFiles {
            if let highest = files.compactMap(CEFExtensionFolderPlan.revision(inWorkerFile:)).max() { revisions[id] = highest }
        }
        return CEFExtensionProfileState(current: [:], known: foldersOnDisk.keys.sorted(), lifecycle: nil, revisions: revisions)
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// The grants the user approved for Chromium tabs, per extension id, kept
/// in their own file (`approvals.json` beside `state.json`) so recording one
/// never rewrites the launch state.
public enum CEFExtensionApprovals {
    public enum Read: Equatable {
        case absent
        case unreadable
        case approvals([String: [String]])
    }

    public static func read(_ url: URL) -> Read {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url),
              let approvals = try? JSONDecoder().decode([String: [String]].self, from: data) else { return .unreadable }
        return .approvals(approvals)
    }

    public static func save(_ approvals: [String: [String]], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(approvals).write(to: url, options: .atomic)
    }
}

/// What to do with a profile's prepared copies at launch, before Chromium
/// starts.
public struct CEFExtensionFolderPlan: Equatable, Sendable {
    /// Copies that are still right, by extension id: folder name.
    public var reuse: [String: String]
    /// Copies to make, by extension id: a folder name no earlier session has
    /// used.
    public var prepare: [String: String]
    /// Extensions that left the install list: their Chromium data in the
    /// profile goes.
    public var deleteData: [String]

    /// The plan for one profile.
    ///
    /// - Parameters:
    ///   - builds: what the profile runs now.
    ///   - installed: every id on the profile's install list, enabled or not;
    ///     nil when no list could be read, and then nothing is deleted.
    ///   - foldersOnDisk: the copy folders that exist, by extension id.
    ///   - newName: a fresh folder name for a build; called once per copy to
    ///     make, and asked again while it returns a name already on disk.
    public static func make(state: CEFExtensionProfileState, builds: [CEFExtensionBuild], installed: Set<String>?,
                            foldersOnDisk: [String: Set<String>],
                            newName: (CEFExtensionBuild) -> String) -> CEFExtensionFolderPlan {
        var plan = CEFExtensionFolderPlan(reuse: [:], prepare: [:], deleteData: [])
        for build in builds {
            if let copy = state.current[build.id], copy.fingerprint == build.fingerprint,
               foldersOnDisk[build.id]?.contains(copy.folder) == true {
                plan.reuse[build.id] = copy.folder
                continue
            }
            let taken = (foldersOnDisk[build.id] ?? []).union(state.current[build.id].map { [$0.folder] } ?? [])
            let base = safeName(newName(build))
            var name = base
            var attempt = 0
            while taken.contains(name) {
                attempt += 1
                name = "\(base)-\(attempt)"
            }
            plan.prepare[build.id] = name
        }
        if let installed {
            plan.deleteData = Set(state.known).union(state.pendingDeletion).subtracting(installed).sorted()
        }
        return plan
    }

    /// Chromium splits the switch on commas, reserves names starting with
    /// `_`, and a leading `.` marks the preparer's own staging folders.
    static func safeName(_ name: String) -> String {
        var safe = name.replacingOccurrences(of: ",", with: "-").replacingOccurrences(of: "/", with: "-")
        while let first = safe.first, first == "_" || first == "." { safe.removeFirst() }
        return safe.isEmpty ? "copy" : safe
    }

    /// Copy folders to delete once the copies are made: everything not kept.
    public static func foldersToDelete(onDisk: [String: Set<String>], keep: [String: String]) -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for (id, folders) in onDisk {
            let drop = folders.subtracting(keep[id].map { [$0] } ?? [])
            if !drop.isEmpty { out[id] = drop }
        }
        return out
    }

    public enum Revision: Equatable, Sendable {
        /// A store install: its version changes with its content.
        case none
        case use(Int)
        /// The preparer's 65535 is used up: a new copy would repeat a worker
        /// name and version with other code, so none is made.
        case exhausted
    }

    public static let maximumRevision = 65535
    public static let revisionsExhausted =
        "Its folder changed more often than Chromium tabs can follow. Remove it and load it again."

    /// The content revision for a copy about to be made from an unpacked
    /// folder: one more than the last one used for that id, so it only goes
    /// up, and only while the preparer can still make a version from it
    /// (`CEFExtensionShim.preparedVersion`; a four-part store version runs
    /// out earlier than `maximumRevision`).
    public static func nextRevision(for build: CEFExtensionBuild, state: CEFExtensionProfileState,
                                    shimVersion: Int = CEFExtensionShim.version) -> Revision {
        guard build.isUnpacked else { return .none }
        let next = (state.revisions[build.id] ?? 0) + 1
        guard next <= maximumRevision else { return .exhausted }
        if let version = build.sourceVersion,
           CEFExtensionShim.preparedVersion(storeVersion: version, shimVersion: shimVersion, revision: next) == nil {
            return .exhausted
        }
        return .use(next)
    }

    /// The revision in a prepared worker's file name
    /// (`brw-background.v<shim>-<version>-r<revision>.js`), if it has one.
    public static func revision(inWorkerFile name: String) -> Int? {
        guard name.hasSuffix(".js"), let marker = name.range(of: "-r", options: .backwards) else { return nil }
        let digits = name[marker.upperBound..<name.index(name.endIndex, offsetBy: -3)]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    /// A copy folder's name: the store version (only safe characters), the
    /// shim version and a random part, so a name is never used twice.
    public static func folderName(version: String, shimVersion: Int = CEFExtensionShim.version, unique: String) -> String {
        let safe = String(version.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (scalar.properties.isAlphabetic || (48...57).contains(scalar.value) || scalar == ".") ? Character(scalar) : "-"
        })
        return "v\(safe.isEmpty ? "0" : safe)-s\(shimVersion)-\(unique)"
    }
}

/// Where Chromium keeps an extension's data inside a profile folder, by
/// extension id. Only the per-extension entries: shared databases (Local
/// Storage, Session Storage, the service-worker registry) hold their records
/// for every origin in one file and are left alone.
public enum CEFExtensionData {
    public static func profileRelativePaths(for id: String) -> [String] {
        guard ChromeExtensionID.isValid(id) else { return [] }
        let origin = "chrome-extension_\(id)_0"
        return [
            "Local Extension Settings/\(id)",
            "Sync Extension Settings/\(id)",
            "Managed Extension Settings/\(id)",
            "DNR Extension Rules/\(id)",
            "IndexedDB/\(origin).indexeddb.leveldb",
            "IndexedDB/\(origin).indexeddb.blob",
            "databases/\(origin)",
            "File System/\(origin)",
            "Storage/ext/\(id)",
        ]
    }
}

/// A request from the shim (`CEFExtensionShim`), checked. Nothing in a
/// payload is trusted: the extension id and profile come from the bridge,
/// and every URL is checked against them.
public enum CEFExtensionRequest: Equatable, Sendable {
    /// No URL: a new tab page.
    case openTab(url: URL?, active: Bool, pinned: Bool)
    case openWindow(urls: [URL], focused: Bool)
    case openOptionsPage
    case reload
    case webAuthFlow
    case openPopup(windowId: Int?)
    case openClientWindow(url: URL)
    /// The extension's worker started: the reply lists the lifecycle events
    /// it should dispatch (CEFExtensionLifecycle).
    case workerStarted
    /// The worker of the extension's current version became active.
    case workerActivated
    /// The shim dispatched these lifecycle events. Only their names are
    /// read; the versions they belong to are the app's own.
    case lifecycleDelivered([CEFExtensionLifecycle.Event])

    public enum Refusal: Error, Equatable, Sendable {
        case unknownKind(String)
        case malformed
        case urlNotAllowed(String)
        case privateWindow

        public var message: String {
            switch self {
            case .unknownKind(let kind): return "unknown request \(kind)"
            case .malformed: return "malformed request"
            case .urlNotAllowed: return "url not allowed"
            case .privateWindow: return "extensions cannot open private windows"
            }
        }
    }

    /// More is a runaway, not a window.
    public static let maximumWindowURLs = 25

    /// The request token in a body (top-level `token`), if any.
    public static func token(in payloadJSON: String) -> String? {
        guard let data = payloadJSON.data(using: .utf8),
              let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return body["token"] as? String
    }

    /// http, https, or a page of the extension that asked. Never another
    /// extension's page, a file, `javascript:` or `data:`.
    public static func isAllowed(_ url: URL, extensionId: String) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "http", "https":
            return !(url.host ?? "").isEmpty
        case "chrome-extension":
            return url.host == extensionId && ChromeExtensionID.isValid(extensionId)
        default:
            return false
        }
    }

    public static func parse(kind: String, payloadJSON: String, extensionId: String) -> Result<CEFExtensionRequest, Refusal> {
        guard let data = payloadJSON.data(using: .utf8),
              let body = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any]
        else { return .failure(.malformed) }
        let detail = body["detail"] as? [String: Any] ?? [:]
        let base = URL(string: "chrome-extension://\(extensionId)/")

        func checked(_ value: Any?) -> Result<URL?, Refusal> {
            guard let value else { return .success(nil) }
            guard let text = value as? String, !text.isEmpty,
                  let url = URL(string: text, relativeTo: base)?.absoluteURL else { return .failure(.malformed) }
            return isAllowed(url, extensionId: extensionId) ? .success(url) : .failure(.urlNotAllowed(url.absoluteString))
        }

        switch kind {
        case "tabs.create":
            return checked(detail["url"]).map {
                .openTab(url: $0, active: detail["active"] as? Bool ?? true, pinned: detail["pinned"] as? Bool ?? false)
            }
        case "windows.create":
            if detail["incognito"] as? Bool == true { return .failure(.privateWindow) }
            var urls: [URL] = []
            let raw: [Any] = (detail["url"] as? [Any]) ?? (detail["url"].map { [$0] } ?? [])
            guard raw.count <= maximumWindowURLs else { return .failure(.malformed) }
            for value in raw {
                switch checked(value) {
                case .success(let url): if let url { urls.append(url) }
                case .failure(let refusal): return .failure(refusal)
                }
            }
            return .success(.openWindow(urls: urls, focused: detail["focused"] as? Bool ?? true))
        case "runtime.openOptionsPage":
            return .success(.openOptionsPage)
        case "runtime.reload":
            return .success(.reload)
        case "identity.launchWebAuthFlow":
            return .success(.webAuthFlow)
        case "action.openPopup":
            let windowId = (detail["windowId"] as? NSNumber).map(\.intValue)
            return .success(.openPopup(windowId: windowId))
        case "worker.started":
            return .success(.workerStarted)
        case "worker.activated":
            return .success(.workerActivated)
        case "lifecycle.delivered":
            guard let raw = detail["delivered"] as? [Any], !raw.isEmpty, raw.count <= 4 else { return .failure(.malformed) }
            var events: [CEFExtensionLifecycle.Event] = []
            for item in raw {
                guard let item = item as? [String: Any], let name = item["event"] as? String else { return .failure(.malformed) }
                switch (name, item["reason"] as? String) {
                case ("onInstalled", "install"): events.append(.installed)
                case ("onInstalled", "update"):
                    guard let previous = item["previousVersion"] as? String else { return .failure(.malformed) }
                    events.append(.updated(previousVersion: previous))
                case ("onStartup", _): events.append(.startup)
                default: return .failure(.malformed)
                }
            }
            return .success(.lifecycleDelivered(events))
        case "clients.openWindow":
            switch checked(detail["url"]) {
            case .success(let url):
                guard let url else { return .failure(.malformed) }
                return .success(.openClientWindow(url: url))
            case .failure(let refusal):
                return .failure(refusal)
            }
        default:
            return .failure(.unknownKind(kind))
        }
    }

    /// The extension's options page from its manifest (`options_ui.page`,
    /// else `options_page`), as a URL of that extension; nil when it has
    /// none or names something outside itself.
    public static func optionsPage(manifest: [String: Any], extensionId: String) -> URL? {
        let page = ((manifest["options_ui"] as? [String: Any])?["page"] as? String) ?? (manifest["options_page"] as? String)
        guard let page, !page.isEmpty, let base = URL(string: "chrome-extension://\(extensionId)/"),
              let url = URL(string: page, relativeTo: base)?.absoluteURL, isAllowed(url, extensionId: extensionId),
              url.scheme == "chrome-extension" else { return nil }
        return url
    }

    /// The extension's toolbar popup page from its manifest, as above.
    public static func popupPage(manifest: [String: Any], extensionId: String) -> URL? {
        let action = (manifest["action"] as? [String: Any]) ?? (manifest["browser_action"] as? [String: Any])
        guard let page = action?["default_popup"] as? String, !page.isEmpty,
              let base = URL(string: "chrome-extension://\(extensionId)/"),
              let url = URL(string: page, relativeTo: base)?.absoluteURL, url.scheme == "chrome-extension",
              isAllowed(url, extensionId: extensionId) else { return nil }
        return url
    }
}

/// A digest of a folder tree's shape: relative paths, sizes and modification
/// dates, never following a link. Cheap enough to take at every launch.
public enum CEFExtensionTreeStamp {
    public static func stamp(of folder: URL) -> String? {
        let files = FileManager.default
        let root = folder.resolvingSymlinksInPath()
        guard let walker = files.enumerator(atPath: root.path) else { return nil }
        var lines: [String] = []
        while let path = walker.nextObject() as? String {
            if path == "_metadata" {
                walker.skipDescendants()
                continue
            }
            // attributesOfItem does not follow a link: a link is listed, never walked.
            let attributes = (try? files.attributesOfItem(atPath: root.appendingPathComponent(path).path)) ?? [:]
            let type = attributes[.type] as? FileAttributeType
            let kind = type == .typeSymbolicLink ? "l" : (type == .typeDirectory ? "d" : "f")
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            lines.append("\(kind)|\(path)|\(size)|\(Int64(date * 1000))")
        }
        lines.sort()
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
