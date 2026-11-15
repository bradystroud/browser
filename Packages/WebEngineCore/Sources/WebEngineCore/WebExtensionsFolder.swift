import Foundation

/// Where a profile keeps everything about its extensions:
/// `<profile dir>/WebExtensions/` -- `installed.json`, each store package
/// in `<id>/`, and each engine's prepared copies (`webkit/`, `cef/`).
///
/// Never `<profile dir>/Extensions/`. The profile directory is also CEF's
/// `cache_path`, which makes `Extensions/` Chromium's own extension install
/// folder, and Chromium's ExtensionGarbageCollector, about 30 seconds after
/// the profile's first CEF tab opens, deletes every folder there it did not
/// install itself. Plain files survive it; packages and copies do not.
public enum WebExtensionsFolder {
    public static let name = "WebExtensions"
    /// Chromium's install folder, where earlier versions kept everything.
    static let chromiumName = "Extensions"
    static let listName = "installed.json"

    public static func directory(inProfile profileDirectory: URL) -> URL {
        profileDirectory.appendingPathComponent(name, isDirectory: true)
    }

    /// The profile's extensions folder, after moving anything of this app's
    /// still in `Extensions/` there (`moveFromChromiumFolder`). A failure to
    /// move is logged through `log` and leaves things where they were; the
    /// next call tries again.
    public static func prepared(inProfile profileDirectory: URL, log: (String) -> Void = { _ in }) -> URL {
        do {
            let moved = try moveFromChromiumFolder(inProfile: profileDirectory)
            if !moved.isEmpty { log("moved \(moved.joined(separator: ", ")) from Extensions/ to \(name)/") }
        } catch {
            log("couldn't move extensions out of Extensions/: \(error.localizedDescription)")
        }
        return directory(inProfile: profileDirectory)
    }

    /// Moves what this app kept in `Extensions/` to `WebExtensions/`, and
    /// returns the names it moved. Only this app's things are touched: the
    /// list, the package folder of each store extension the list names,
    /// `webkit/`, and the staging and set-aside folders of its own naming;
    /// anything Chromium put there stays.
    ///
    /// Safe to interrupt at any point: every item is one rename within the
    /// profile's volume, the list goes last, and the next call finishes the
    /// job. What already exists in `WebExtensions/` is never overwritten --
    /// it is newer than what is left behind, which is then deleted.
    @discardableResult
    public static func moveFromChromiumFolder(inProfile profileDirectory: URL) throws -> [String] {
        let files = FileManager.default
        let old = profileDirectory.appendingPathComponent(chromiumName, isDirectory: true)
        let new = directory(inProfile: profileDirectory)
        let oldList = old.appendingPathComponent(listName)
        guard files.fileExists(atPath: oldList.path) else { return [] }

        var ours = ["webkit"]
        for record in InstalledWebExtensionList.load(from: oldList).extensions where record.source == .webStore {
            ours.append(record.id)
        }
        let present = (try? files.contentsOfDirectory(atPath: old.path)) ?? []
        ours += present.filter { $0.hasPrefix(".staging-") || $0.hasPrefix(".previous-") || $0.hasPrefix(".unpacking-") }

        try files.createDirectory(at: new, withIntermediateDirectories: true)
        var moved: [String] = []
        for item in ours + [listName] {
            let source = old.appendingPathComponent(item)
            guard files.fileExists(atPath: source.path) else { continue }
            let destination = new.appendingPathComponent(item)
            if files.fileExists(atPath: destination.path) {
                try files.removeItem(at: source)
            } else {
                try files.moveItem(at: source, to: destination)
                moved.append(item)
            }
        }
        return moved
    }

    // MARK: - Is a package whole?

    /// What a store package held when this app unpacked it, or first found
    /// it: every regular file by path and size. Kept beside the package as
    /// `<id>.contents.json` and checked at load -- the only way to tell a
    /// whole package from one Chromium's collector emptied part of (for an
    /// id Chromium knows it deletes the subfolders, taking them for stale
    /// versions, and leaves top-level files such as `manifest.json`).
    public struct PackageContents: Codable, Equatable {
        public let files: [String: Int]

        public init(files: [String: Int]) {
            self.files = files
        }

        public static func read(_ folder: URL) throws -> PackageContents {
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
            guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            let base = folder.resolvingSymlinksInPath().path
            var files: [String: Int] = [:]
            for case let url as URL in walker {
                let values = try url.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true else { continue }
                files[String(url.resolvingSymlinksInPath().path.dropFirst(base.count + 1))] = values.fileSize ?? 0
            }
            return PackageContents(files: files)
        }
    }

    public static func contentsRecord(id: String, in extensions: URL) -> URL {
        extensions.appendingPathComponent(id + ".contents.json")
    }

    /// Records what `packageFolder` holds now.
    public static func recordContents(of packageFolder: URL, id: String, in extensions: URL) throws {
        let data = try JSONEncoder().encode(try PackageContents.read(packageFolder))
        try data.write(to: contentsRecord(id: id, in: extensions), options: .atomic)
    }

    public static func forgetContents(id: String, in extensions: URL) {
        try? FileManager.default.removeItem(at: contentsRecord(id: id, in: extensions))
    }

    public enum PackageState: Equatable {
        /// Matches its record.
        case whole
        /// Not there at all.
        case missing
        /// Differs from its record: files gone or changed.
        case damaged
        /// There, with no record yet (unpacked by a version that kept none).
        /// It is loaded as found and recorded then; nothing is downloaded
        /// for it.
        case unverified
    }

    /// What a store extension's package folder is in. A developer's
    /// unpacked folder is theirs, and always `.whole` here.
    public static func packageState(of record: InstalledWebExtension, packageFolder: URL, in extensions: URL) -> PackageState {
        guard record.source == .webStore else { return .whole }
        guard FileManager.default.fileExists(atPath: packageFolder.appendingPathComponent("manifest.json").path) else {
            return .missing
        }
        guard let data = try? Data(contentsOf: contentsRecord(id: record.id, in: extensions)),
              let recorded = try? JSONDecoder().decode(PackageContents.self, from: data)
        else { return .unverified }
        guard let actual = try? PackageContents.read(packageFolder) else { return .damaged }
        return actual == recorded ? .whole : .damaged
    }
}
