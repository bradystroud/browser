import AppKit

/// Holds one profile's start-page background image and hands StartPageRenderer
/// a ready-to-inline `data:` URI for it (browser-1wo).
///
/// The picked file is never referenced where it sits. The start page is itself
/// a `data:` URL -- an opaque origin with no access to `file:` resources -- so
/// the only way a picture can reach it is by travelling inside the document,
/// the same constraint that already forces that renderer to inline favicons.
/// The file is therefore copied into the profile's own directory (keyed by
/// profile id, so it moves with everything else browser-ojw put there), which
/// also means the background survives the user later moving or deleting the
/// original.
///
/// The copy is re-encoded rather than stored byte-for-byte: its base64 form is
/// pasted into a fresh copy of the page on *every* new tab, so a 12-megapixel
/// phone photo would otherwise be paid for over and over.
enum StartPageBackgroundImageStore {
    /// One background per profile, so re-picking overwrites in place instead of
    /// accumulating orphaned files. Always `.jpg` because `install` always
    /// re-encodes to JPEG.
    static let fileName = "startpage-background.jpg"

    /// Longest edge kept, in pixels. The image is drawn `cover` behind a
    /// browser window, so resolution past a Retina window's own pixel width
    /// buys nothing visible and costs base64 weight in every new tab.
    private static let maxPixelDimension: CGFloat = 2560
    private static let jpegQuality: Double = 0.7

    /// Encoded-once cache of the `data:` URI, keyed by profile id. Populated
    /// on the first start page rendered for a profile and dropped whenever
    /// that profile's image changes, so opening ten new tabs doesn't base64
    /// several hundred kilobytes ten times. Main-thread only, like every other
    /// caller in this file -- rendering and the settings pane both run there.
    private static var dataURICache: [String: String] = [:]

    /// Copies `sourceURL` in as `profileId`'s background, downscaled and
    /// re-encoded. Returns false (leaving any existing background untouched)
    /// if the file isn't a readable image or can't be written -- callers
    /// surface that rather than recording a background that isn't there.
    static func install(from sourceURL: URL, forProfileId profileId: String) -> Bool {
        guard let image = NSImage(contentsOf: sourceURL),
              let jpeg = downscaledJPEG(from: image) else { return false }

        let url = fileURL(forProfileId: profileId)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try jpeg.write(to: url, options: .atomic)
        } catch {
            return false
        }
        dataURICache[profileId] = nil
        return true
    }

    static func remove(forProfileId profileId: String) {
        try? FileManager.default.removeItem(at: fileURL(forProfileId: profileId))
        dataURICache[profileId] = nil
    }

    /// The stored image as a `data:` URI ready to drop into CSS, or nil if
    /// this profile has none on disk. Nil is a normal result, not an error:
    /// settings can name a background whose file has since been deleted out
    /// from under us, and the renderer/settings pane both fall back cleanly.
    static func dataURI(forProfileId profileId: String) -> String? {
        if let cached = dataURICache[profileId] { return cached }
        guard let data = try? Data(contentsOf: fileURL(forProfileId: profileId)) else { return nil }
        let uri = "data:image/jpeg;base64,\(data.base64EncodedString())"
        dataURICache[profileId] = uri
        return uri
    }

    /// The stored image itself, for the settings pane's thumbnail. Also the
    /// existence check that pane uses, since a nil here is exactly the
    /// "recorded but no longer on disk" case described above.
    static func image(forProfileId profileId: String) -> NSImage? {
        NSImage(contentsOf: fileURL(forProfileId: profileId))
    }

    // MARK: - Internals

    private static func fileURL(forProfileId profileId: String) -> URL {
        URL(fileURLWithPath: CommandLineArgs.profileDirectory(profileId: profileId))
            .appendingPathComponent(fileName)
    }

    private static func downscaledJPEG(from image: NSImage) -> Data? {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }

        let sourceWidth = CGFloat(cgImage.width)
        let sourceHeight = CGFloat(cgImage.height)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        // Never upscales: a small picture stays its own size rather than being
        // blown up into a bigger, blurrier, heavier file.
        let scale = min(1, maxPixelDimension / max(sourceWidth, sourceHeight))
        let targetWidth = max(1, Int((sourceWidth * scale).rounded()))
        let targetHeight = max(1, Int((sourceHeight * scale).rounded()))

        // 4 samples with alpha, even though the JPEG this ends up as has no
        // alpha channel at all: a 24-bit RGB bitmap is not a format
        // CGBitmapContext supports, so NSGraphicsContext(bitmapImageRep:)
        // below returns nil for one and every install fails -- confirmed
        // against a real photograph, not assumed.
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetWidth,
            pixelsHigh: targetHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: targetWidth, height: targetHeight)

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let bounds = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        // JPEG has no alpha channel, so a transparent PNG would composite onto
        // whatever the fresh bitmap happens to hold -- white matches the light
        // page this sits behind.
        context.cgContext.setFillColor(gray: 1, alpha: 1)
        context.cgContext.fill(bounds)
        context.cgContext.draw(cgImage, in: bounds)
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
    }
}
