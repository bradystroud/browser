import Foundation

/// Why an extension could not be installed, loaded or updated, in words the
/// Extensions window can show as they are.
enum WebKitExtensionError: LocalizedError {
    case unavailable
    case notAWebStoreLink
    case alreadyInstalled(String)
    case busy
    case noManifest
    case download(Int)
    case emptyDownload
    case tooLarge
    case unpackFailed
    /// The user said no; nothing to report.
    case cancelled
    case notInstalled

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Extensions aren't available in this window."
        case .notAWebStoreLink: return "That isn't a Chrome Web Store link or extension id."
        case .alreadyInstalled(let name): return "\(name) is already installed."
        case .busy: return "That extension is already being installed or updated."
        case .noManifest: return "That folder has no manifest.json."
        case .download(let status): return "The Chrome Web Store answered \(status)."
        case .emptyDownload: return "The Chrome Web Store has nothing for that id -- it may have been taken down."
        case .tooLarge: return "The extension package is too large."
        case .unpackFailed: return "The extension couldn't be unpacked."
        case .cancelled: return nil
        case .notInstalled: return "That extension isn't installed."
        }
    }
}

/// Fetching a package from the Chrome Web Store and turning it into a folder
/// WebKit can load. Nothing here touches WebKit, so every step can be
/// refused before an extension's code is ever read.
enum WebKitExtensionInstaller {
    /// Well above any real extension (uBlock Origin Lite is about 10 MB),
    /// well below what would fill a disk.
    static let maximumPackageBytes = 256 * 1024 * 1024

    /// Stands in for the Chrome Web Store in tests; nil fetches from it.
    static var fetchOverride: ((String) async throws -> Data)?

    static func fetchPackage(id: String) async throws -> Data {
        if let fetchOverride { return try await fetchOverride(id) }
        var request = URLRequest(url: ChromeWebStore.downloadURL(for: id))
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WebKitExtensionError.download(http.statusCode)
        }
        guard !data.isEmpty else { throw WebKitExtensionError.emptyDownload }
        guard data.count <= maximumPackageBytes else { throw WebKitExtensionError.tooLarge }
        return data
    }

    /// Downloads `id`, checks its signature against the id, and unpacks it
    /// into a fresh staging folder inside `directory`. The caller moves the
    /// folder into place or deletes it. `publicKey`, when given, receives the
    /// developer key the signature check proved (see `CRXPublicKeySink`).
    static func downloadAndStage(id: String, in directory: URL, publicKey: CRXPublicKeySink? = nil) async throws -> URL {
        let crx = try await fetchPackage(id: id)
        return try await Task.detached(priority: .userInitiated) {
            let zip = try CRXPublicKeySink.verifiedArchive(crx, expectedID: id, keepingKeyIn: publicKey)
            let staged = directory.appendingPathComponent(".staging-\(id)-\(UUID().uuidString)", isDirectory: true)
            try unpack(zip, into: staged)
            return staged
        }.value
    }

    /// Extracts the archive in-process (see ZipArchive for everything that
    /// refuses it whole) into `folder`, which is replaced. Nothing is ever
    /// written through a link, so no entry can land outside the folder.
    static func unpack(_ zip: Data, into folder: URL) throws {
        let files = FileManager.default
        let scratch = folder.deletingLastPathComponent()
            .appendingPathComponent(".unpacking-\(UUID().uuidString)", isDirectory: true)
        do {
            try ZipArchive.extract(zip, into: scratch)
        } catch {
            try? files.removeItem(at: scratch)
            throw error
        }
        guard files.fileExists(atPath: scratch.appendingPathComponent("manifest.json").path) else {
            try? files.removeItem(at: scratch)
            throw WebKitExtensionError.unpackFailed
        }
        try? files.removeItem(at: folder)
        try files.moveItem(at: scratch, to: folder)
    }

    /// Where WebKit's prepared copies of store extensions live, beside the
    /// packages in the profile's extensions folder.
    static func webKitCopies(in directory: URL) -> URL {
        directory.appendingPathComponent("webkit", isDirectory: true)
    }

    /// The folder WebKit loads a store extension from. The package's own
    /// folder, `<extensions>/<id>/`, stays exactly as it unpacked, because
    /// another engine prepares its own copy from it; WebKit gets
    /// `<extensions>/webkit/<id>/` with the Chrome compatibility layer
    /// (`PreparedExtensionCopy`) when the layer applies, and the package
    /// itself when it does not. A package folder the layer was once written
    /// into is put back first. Failures are logged, not thrown: the
    /// extension then loads from what there is, as it did before the layer.
    ///
    /// File work only; never on the main thread.
    static func webKitFolder(forPackage folder: URL, id: String, in directory: URL) -> URL {
        do {
            if try PreparedExtensionCopy.restorePristine(folder) {
                NSLog("Browser: took the Chrome compatibility layer out of extension %@'s package folder", id)
            }
        } catch {
            NSLog("Browser: couldn't restore extension %@'s package folder: %@", id, error.localizedDescription)
        }
        do {
            if let copy = try PreparedExtensionCopy.ensure(pristine: folder, copies: webKitCopies(in: directory), id: id) {
                return copy
            }
        } catch {
            NSLog("Browser: couldn't prepare extension %@ for WebKit: %@", id, error.localizedDescription)
        }
        return folder
    }

    /// WebKit's copy of a store extension that is being removed.
    static func removeWebKitCopy(id: String, in directory: URL) {
        PreparedExtensionCopy.remove(id: id, in: webKitCopies(in: directory))
    }

    /// Puts `staged` where `destination` is. The old folder is kept aside
    /// until the new one is in place, so a failed move leaves the installed
    /// version as it was.
    static func replace(_ destination: URL, with staged: URL) throws {
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

    /// Staging and set-aside folders a crash or quit left behind, among the
    /// packages and among WebKit's copies.
    static func removeLeftovers(in directory: URL) {
        let files = FileManager.default
        for folder in [directory, webKitCopies(in: directory)] {
            guard let names = try? files.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names where name.hasPrefix(".staging-") || name.hasPrefix(".previous-") || name.hasPrefix(".unpacking-") {
                try? files.removeItem(at: folder.appendingPathComponent(name))
            }
        }
    }
}
