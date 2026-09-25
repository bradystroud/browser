import AppKit

/// A small per-window LRU cache of tab thumbnail snapshots (browser-rhi.3),
/// keyed by Tab.id. Captured at deactivation time only (see
/// BrowserWindowController.activateTab's captureThumbnail(for:) call) --
/// NSView.cacheDisplay(in:to:) needs the view still attached to a window to
/// paint reliably, and a tab's hostView is only ever guaranteed to be in
/// that state right before it's detached on its way out as the active tab,
/// never once it's already sitting inactive offscreen. A tab that's never
/// been deactivated this session (including a lazy-restored tab that's
/// never even had its browser created) simply has no entry -- the Tab
/// Overview grid falls back to a favicon+title placeholder for those.
///
/// A capture arrives as a full-window bitmap at the backing scale (tens of
/// MB for a large Retina window), so setImage(_:for:) downscales it to
/// maxPixelWidth before retaining it: the overview grid draws each
/// thumbnail into a cell well under 200pt wide, so anything larger is
/// memory spent on pixels nobody sees. Capped at maxEntries as well,
/// evicting the least-recently-set entry once full, so a window with
/// hundreds of tab switches over a long session stays bounded.
final class TabThumbnailCache {
    /// TabOverviewView's 180pt cell at 2x, doubled for headroom, so the grid
    /// never has to upscale a thumbnail.
    static let maxPixelWidth = 720

    private var images: [UUID: NSImage] = [:]
    private var order: [UUID] = []
    private let maxEntries: Int

    init(maxEntries: Int = 30) {
        self.maxEntries = maxEntries
    }

    func image(for tabId: UUID) -> NSImage? {
        images[tabId]
    }

    func setImage(_ image: NSImage, for tabId: UUID) {
        if images[tabId] == nil {
            order.append(tabId)
        } else {
            order.removeAll { $0 == tabId }
            order.append(tabId)
        }
        images[tabId] = Self.downscaled(image)
        while order.count > maxEntries {
            let oldest = order.removeFirst()
            images.removeValue(forKey: oldest)
        }
    }

    /// Called when a tab closes -- no point keeping a snapshot around for a
    /// tab that no longer exists.
    func removeImage(for tabId: UUID) {
        images.removeValue(forKey: tabId)
        order.removeAll { $0 == tabId }
    }

    /// Redraws `image` into a fresh bitmap no wider than maxPixelWidth,
    /// keeping its aspect ratio and point size, so the original full-size
    /// representation can be released. Returns `image` itself when it is
    /// already small enough or cannot be redrawn.
    private static func downscaled(_ image: NSImage) -> NSImage {
        let sourceWidth = image.representations.map(\.pixelsWide).max() ?? 0
        guard sourceWidth > maxPixelWidth, image.size.width > 0, image.size.height > 0 else {
            return image
        }
        let pixelWidth = maxPixelWidth
        let pixelHeight = max(1, Int((CGFloat(pixelWidth) * image.size.height / image.size.width).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelWidth, pixelsHigh: pixelHeight,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return image
        }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let scaled = NSImage(size: image.size)
        scaled.addRepresentation(rep)
        return scaled
    }
}
