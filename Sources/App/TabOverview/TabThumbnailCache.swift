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
/// Capped at maxEntries, evicting the least-recently-set entry once full:
/// a handful of NSImages at tab-strip-content-sized capture resolution is
/// cheap, but a window with hundreds of tab switches over a long session
/// shouldn't accumulate an unbounded number of them.
final class TabThumbnailCache {
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
        images[tabId] = image
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
}
