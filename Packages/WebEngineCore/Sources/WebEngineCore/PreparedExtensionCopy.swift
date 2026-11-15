import CryptoKit
import Foundation

/// Undoing `ChromeExtensionCompatibility.prepare(folder:)`, for a folder the
/// layer was once written into directly. The store package's own folder
/// must stay as it unpacked: another engine prepares its own copy from it.
extension ChromeExtensionCompatibility {
    public enum ReversalError: Error, Equatable, LocalizedError {
        /// The manifest names the layer's worker, but the file there is not
        /// one the layer wrote, so the original worker cannot be known.
        case unreadableWrapper

        public var errorDescription: String? {
            "The extension's background worker was changed by something other than this browser."
        }
    }

    /// Whether the layer was written into `folder`.
    public static func isPrepared(folder: URL) -> Bool {
        let files = FileManager.default
        return files.fileExists(atPath: folder.appendingPathComponent(shimFile).path)
            || files.fileExists(atPath: folder.appendingPathComponent(workerFile).path)
    }

    /// Puts `folder` back as it was before `prepare(folder:)`: the two files
    /// it added are deleted, the shim's tag comes out of every page, the
    /// worker the wrapper named goes back into the manifest, and the shim
    /// leaves `background.scripts`. Every file but the manifest comes back
    /// byte for byte; the manifest comes back with the same content, in the
    /// layout `prepare` wrote it in, since its original bytes were not kept.
    public static func unprepare(folder: URL) throws {
        var manifest = try readManifest(in: folder)
        if var background = manifest["background"] as? [String: Any] {
            var changed = false
            if (background["service_worker"] as? String) == workerFile {
                guard let wrapper = try? String(contentsOf: folder.appendingPathComponent(workerFile), encoding: .utf8),
                      let original = originalWorker(in: wrapper)
                else { throw ReversalError.unreadableWrapper }
                background["service_worker"] = original
                changed = true
            }
            if var scripts = background["scripts"] as? [Any], (scripts.first as? String) == shimFile {
                scripts.removeFirst()
                background["scripts"] = scripts
                changed = true
            }
            if changed {
                manifest["background"] = background
                let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                try data.write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
            }
        }
        let tag = Data(scriptTag.utf8)
        for page in htmlPages(in: folder) {
            guard var bytes = try? Data(contentsOf: page), bytes.range(of: tag) != nil else { continue }
            while let range = bytes.range(of: tag) { bytes.removeSubrange(range) }
            try bytes.write(to: page, options: .atomic)
        }
        for name in [workerFile, shimFile] {
            let url = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    /// The original worker a wrapper written by `workerSource` loads: the
    /// second string in it, the first being the shim. The leading slash
    /// `prepare` added is taken off again.
    static func originalWorker(in wrapper: String) -> String? {
        guard wrapper.hasPrefix(workerHeader) else { return nil }
        let body = wrapper.dropFirst(workerHeader.count)
        var strings: [String] = []
        var index = body.startIndex
        while let open = body[index...].firstIndex(of: "\"") {
            var cursor = body.index(after: open)
            var escaped = false
            while cursor < body.endIndex {
                let character = body[cursor]
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { break }
                cursor = body.index(after: cursor)
            }
            guard cursor < body.endIndex,
                  let decoded = try? JSONSerialization.jsonObject(with: Data(("[" + body[open...cursor] + "]").utf8)) as? [String],
                  let string = decoded.first
            else { return nil }
            strings.append(string)
            index = body.index(after: cursor)
        }
        guard strings.count == 2, strings[0] == "/" + shimFile else { return nil }
        let original = String(strings[1].drop { $0 == "/" })
        return original.isEmpty ? nil : original
    }
}

/// An engine's own prepared copy of a store extension, derived from the
/// package's untouched folder: `<copies>/<id>/`, with `<copies>/<id>.json`
/// recording what it was built from. It is rebuilt whenever the package or
/// the layer changes, always in a staging folder that is swapped in whole,
/// so a crash leaves either the old copy or the new one.
public enum PreparedExtensionCopy {
    /// Bumped when the copy's layout changes in a way the shim's own text
    /// does not show.
    static let format = "1"

    private struct Stamp: Codable, Equatable {
        let fingerprint: String
    }

    public static func copyFolder(id: String, in copies: URL) -> URL { copies.appendingPathComponent(id, isDirectory: true) }
    static func stampFile(id: String, in copies: URL) -> URL { copies.appendingPathComponent(id + ".json") }

    /// The folder the engine should load: the prepared copy when the layer
    /// applies (built or refreshed as needed), and nil when it does not --
    /// then the package's own folder is loaded as it is, and any copy left
    /// from an earlier version is deleted.
    public static func ensure(pristine: URL, copies: URL, id: String) throws -> URL? {
        let copy = copyFolder(id: id, in: copies)
        let stampURL = stampFile(id: id, in: copies)
        guard ChromeExtensionCompatibility.isNeeded(folder: pristine) else {
            remove(id: id, in: copies)
            return nil
        }
        let wanted = Stamp(fingerprint: try fingerprint(of: pristine))
        if let data = try? Data(contentsOf: stampURL), (try? JSONDecoder().decode(Stamp.self, from: data)) == wanted,
           FileManager.default.fileExists(atPath: copy.appendingPathComponent("manifest.json").path) {
            return copy
        }
        try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
        let staging = copies.appendingPathComponent(".staging-\(id)-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.copyItem(at: pristine, to: staging)
            try ChromeExtensionCompatibility.prepare(folder: staging)
            try swap(copy, with: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        try JSONEncoder().encode(wanted).write(to: stampURL, options: .atomic)
        return copy
    }

    /// Deletes the copy and its stamp, if any.
    public static func remove(id: String, in copies: URL) {
        try? FileManager.default.removeItem(at: copyFolder(id: id, in: copies))
        try? FileManager.default.removeItem(at: stampFile(id: id, in: copies))
    }

    /// Brings a package folder the layer was once written into back to the
    /// package, through a staged copy swapped in whole. Returns whether it
    /// had to.
    @discardableResult
    public static func restorePristine(_ folder: URL) throws -> Bool {
        guard ChromeExtensionCompatibility.isPrepared(folder: folder) else { return false }
        let staging = folder.deletingLastPathComponent()
            .appendingPathComponent(".staging-\(folder.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.copyItem(at: folder, to: staging)
            try ChromeExtensionCompatibility.unprepare(folder: staging)
            try swap(folder, with: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        return true
    }

    /// What a copy was built from: the layer (shim text and this format)
    /// and every file of the package by path, size and modification time.
    /// The package changes only when it is installed or updated, which
    /// rewrites its files.
    static func fingerprint(of pristine: URL) throws -> String {
        var hash = SHA256()
        hash.update(data: Data(format.utf8))
        hash.update(data: Data(ChromeExtensionCompatibility.shimSource.utf8))
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: pristine, includingPropertiesForKeys: keys) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let base = pristine.resolvingSymlinksInPath().path
        var entries: [String] = []
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let path = String(url.resolvingSymlinksInPath().path.dropFirst(base.count))
            let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            entries.append("\(path)\u{0}\(values.fileSize ?? 0)\u{0}\(modified)")
        }
        for entry in entries.sorted() { hash.update(data: Data((entry + "\n").utf8)) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Puts `staged` where `destination` is, keeping the old folder aside
    /// until the new one is in place.
    static func swap(_ destination: URL, with staged: URL) throws {
        let files = FileManager.default
        let aside = destination.deletingLastPathComponent()
            .appendingPathComponent(".previous-\(destination.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
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
