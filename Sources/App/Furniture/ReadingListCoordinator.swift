import AppKit

/// Ties the reading list together (browser-56p): saving the current page,
/// capturing its article for offline reading, and opening a saved item
/// back up again.
///
/// Saving and capturing are two steps, because capture has to go out to the
/// page and come back (see ReadingListStore's own doc comment). The item is
/// recorded the instant ⇧⌘D is pressed, so the UI can answer immediately;
/// the offline copy lands whenever the page answers, or never, and the item
/// is perfectly usable either way.
final class ReadingListCoordinator {
    static let shared = ReadingListCoordinator()

    /// A capture that has been asked for but not yet answered. Keyed by the
    /// URL the script was given, which is what comes back in the reply --
    /// not by tab, because the tab may well have navigated on by then and
    /// the answer still belongs to the page that was saved.
    private struct PendingCapture {
        let itemId: Int64
        let profile: Profile
        let requestedAt: Date
    }

    /// How long a capture may stay outstanding before it is forgotten. A
    /// page that never answers (the script threw, the tab was closed
    /// mid-parse) must not hold an entry for the rest of the session.
    private static let captureTimeout: TimeInterval = 60

    private var isActivated = false
    private var pendingCaptures: [String: PendingCapture] = [:]

    private init() {}

    func activate() {
        guard !isActivated else { return }
        isActivated = true
        PageMessageDispatcher.shared.activate()
        PageMessageDispatcher.shared.register(types: [ReadingListCaptureScript.messageType]) { [weak self] _, request, requestId, tab in
            self?.handleCaptureReply(request: request, requestId: requestId, tab: tab)
        }
    }

    func store(for profile: Profile) -> ReadingListStore {
        ProfileDataStoreManager.shared.stores(for: profile).readingList
    }

    // MARK: - Saving

    /// Saves `tab`'s current page and asks the page for its article.
    /// Returns false when there is nothing to save -- an internal page, or
    /// a tab showing the start page, neither of which has an address worth
    /// keeping.
    ///
    /// A private window is allowed to save. Saving is an explicit request
    /// to keep something, the same as a bookmark, and private browsing
    /// promises not to record where you went by itself -- not to refuse
    /// what you deliberately ask it to keep.
    @discardableResult
    func add(tab: Tab, profile: Profile) -> Bool {
        let url = tab.urlString
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else { return false }

        let title = tab.displayTitle
        do {
            let id = try store(for: profile).add(url: url, title: title)
            requestCapture(for: id, url: url, title: title, tab: tab, profile: profile)
            return true
        } catch {
            NSLog("Browser: failed to add %@ to the reading list: %@", url, String(describing: error))
            return false
        }
    }

    func isSaved(url: String, profile: Profile) -> Bool {
        (try? store(for: profile).contains(url: url)) ?? false
    }

    private func requestCapture(for itemId: Int64, url: String, title: String, tab: Tab, profile: Profile) {
        forgetStaleCaptures()
        pendingCaptures[url] = PendingCapture(itemId: itemId, profile: profile, requestedAt: Date())
        tab.executeJavaScript(ReadingListCaptureScript.source(url: url, title: title))
    }

    private func forgetStaleCaptures() {
        let cutoff = Date().addingTimeInterval(-Self.captureTimeout)
        pendingCaptures = pendingCaptures.filter { $0.value.requestedAt > cutoff }
    }

    // MARK: - Capture replies

    private struct CaptureReply: Decodable {
        let url: String
        let ok: Bool
        let title: String?
        let byline: String?
        let excerpt: String?
        let content: String?
    }

    private func handleCaptureReply(request: String, requestId: Int64, tab: Tab) {
        // Ack first, whatever happens next: the script retries until it is
        // acked, and a reply we cannot use is still a reply that arrived.
        tab.respondToPageMessage(requestId: requestId, success: true, response: "")

        guard let data = request.data(using: .utf8),
              let reply = try? JSONDecoder().decode(CaptureReply.self, from: data),
              let pending = pendingCaptures.removeValue(forKey: reply.url) else { return }
        guard reply.ok, let content = reply.content else {
            // Extraction failed. The item stays on the list without an
            // offline copy, which is a real state the UI shows -- opening
            // it will just need the network.
            return
        }

        do {
            try store(for: pending.profile).saveArticle(
                id: pending.itemId,
                content: content,
                byline: reply.byline ?? "",
                excerpt: reply.excerpt ?? ""
            )
        } catch {
            NSLog("Browser: failed to store the offline copy of %@: %@", reply.url, String(describing: error))
        }
    }

    // MARK: - Reading

    /// Where a saved item should be opened, marking it read on the way --
    /// which is what reading it means, and what Safari does.
    ///
    /// The offline copy is preferred whenever there is one, even with a
    /// working connection: it is the version the user saved, it renders
    /// instantly, and it cannot have changed underneath them. An item with
    /// no offline copy falls back to its original URL, which is the one
    /// case that still needs the network.
    ///
    /// Returns a URL rather than driving a tab itself so that every caller
    /// -- the list window, the start page, a menu item -- reaches a page
    /// the same way it opens any other link.
    func navigationURL(for item: ReadingListItem, profile: Profile) -> String {
        let store = store(for: profile)
        if !item.isRead {
            try? store.markRead(id: item.id)
        }
        guard item.hasArticle, let content = try? store.article(id: item.id) else { return item.url }
        return ReadingListArticleTemplate.dataURL(for: item, content: content)
    }
}
