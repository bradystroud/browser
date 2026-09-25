import AppKit

/// Fetches, caches, and serves tab favicons.
///
/// - In-memory cache keyed by host, so switching between already-visited
///   tabs never re-fetches.
/// - On-disk cache per profile, under the same directory CEF already uses
///   for that profile's own cache (see CommandLineArgs.profileDirectory) --
///   `<profilesRootPath>/<profileId>/BrowserFavicons/<host>.png`, keyed by
///   the profile's stable id rather than its mutable name (browser-ojw) --
///   so icons survive both a relaunch and a profile rename without needing
///   the network again. Deliberately not named `Favicons`: CEF/Chromium
///   already creates its own file with that exact name (a SQLite database)
///   directly in this same directory, so `createDirectory` would silently
///   fail against it every time (browser-c0m) -- `BrowserFavicons` can't
///   collide with any of Chromium's own fixed per-profile filenames.
/// - No third-party favicon services: this only ever talks to the site's
///   own host, for privacy.
/// - Fetches use an ephemeral session: no cookies and no HTTP disk cache,
///   so a favicon request can neither link profiles together nor leave a
///   record of a private window's visits in the app's Caches directory.
///   A private profile's icons are likewise never written to (or read from)
///   the on-disk cache above.
///
/// Prefers the page's own declared favicon URL when available (`hintURL`,
/// forwarded from CefDisplayHandler::OnFaviconURLChange via
/// BRWBrowserDelegate.browserDidChangeFaviconURL -- see Tab.swift), since
/// that reflects whatever `<link rel="icon">` the page actually declares,
/// including non-default paths. Falls back to guessing
/// `https://<host>/favicon.ico` when no hint has arrived yet.
final class FaviconLoader {
    static let shared = FaviconLoader()

    /// Only touched on `queue`.
    private var memoryCache: [String: NSImage] = [:]
    private let queue = DispatchQueue(label: "dev.stroud.browser.faviconloader")
    private let session = URLSession(configuration: .ephemeral)
    private let targetSize = NSSize(width: 32, height: 32) // @2x for a 16pt tab icon slot

    private init() {}

    func loadFavicon(host: String, hintURL: String?, profileId: String, completion: @escaping (NSImage?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }

            if let cached = self.memoryCache[host] {
                DispatchQueue.main.async { completion(cached) }
                return
            }

            let diskURL = self.diskCacheURL(host: host, profileId: profileId)
            if let diskURL, let data = try? Data(contentsOf: diskURL), let image = self.decodedImage(from: data) {
                self.memoryCache[host] = image
                DispatchQueue.main.async { completion(image) }
                return
            }

            guard let fetchURL = self.resolvedFetchURL(host: host, hintURL: hintURL) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let task = self.session.dataTask(with: fetchURL) { [weak self] data, response, _ in
                guard let self else { return }
                guard let data, let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200,
                      let image = self.decodedImage(from: data) else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                self.queue.async {
                    self.memoryCache[host] = image
                    if let diskURL {
                        self.saveToDisk(image: image, url: diskURL)
                    }
                    DispatchQueue.main.async { completion(image) }
                }
            }
            task.resume()
        }
    }

    private func resolvedFetchURL(host: String, hintURL: String?) -> URL? {
        if let hintURL, let url = URL(string: hintURL), url.scheme == "http" || url.scheme == "https" {
            return url
        }
        return URL(string: "https://\(host)/favicon.ico")
    }

    /// Validates the fetched bytes actually decode as an image -- a 404 page
    /// or captive-portal redirect served with a 200 status would otherwise
    /// poison the cache with garbage.
    private func decodedImage(from data: Data) -> NSImage? {
        guard !data.isEmpty, let image = NSImage(data: data), image.isValid,
              image.size.width > 0, image.size.height > 0 else {
            return nil
        }
        return resized(image, to: targetSize)
    }

    private func resized(_ image: NSImage, to size: NSSize) -> NSImage {
        let resized = NSImage(size: size)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1.0)
        resized.unlockFocus()
        return resized
    }

    /// The PNG bytes for a host's already-cached favicon, or nil when nothing
    /// is cached for it. Synchronous, and a cache hit or nothing: it never
    /// touches the network, so any caller may use it on the main thread and on
    /// a render path (see StartPageRenderer, which inlines the bytes as a
    /// `data:` URI). Deliberately reads only the on-disk cache and never the
    /// in-memory one -- `memoryCache` is only safe to touch on this class's
    /// own serial queue, and the disk cache is a superset of it anyway, since
    /// nothing enters memory without also being written to disk.
    func cachedFaviconData(host: String, profileId: String) -> Data? {
        guard let diskURL = diskCacheURL(host: host, profileId: profileId),
              let data = try? Data(contentsOf: diskURL),
              !data.isEmpty, data.count <= Self.maxInlinableBytes else { return nil }
        return data
    }

    /// Entries are our own re-encoded 32x32 PNGs -- 4KB of pixels before
    /// compression, so a few KB on disk; anything near this bound is a
    /// corrupted or hand-placed file. The bound matters because the start page
    /// inlines these bytes into the single `data:` URL that *is* the tab's
    /// URL, so it caps the whole page, not just one tile.
    private static let maxInlinableBytes = 32 * 1024

    /// Nil for a private profile, which has no on-disk cache.
    private func diskCacheURL(host: String, profileId: String) -> URL? {
        guard !profileId.hasPrefix(Profile.privateIdPrefix) else { return nil }
        return cacheDirectoryURL(profileId: profileId).appendingPathComponent("\(host).png")
    }

    private func cacheDirectoryURL(profileId: String) -> URL {
        URL(fileURLWithPath: CommandLineArgs.profileDirectory(profileId: profileId))
            .appendingPathComponent("BrowserFavicons")
    }

    private func saveToDisk(image: NSImage, url: URL) {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? png.write(to: url)
    }
}
