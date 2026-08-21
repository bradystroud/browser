import Foundation

/// A tab that was closed on its own, and where it was, so ⇧⌘T can put it
/// back where it came from rather than at the end of the strip.
struct ClosedTab: Codable, Equatable {
    /// The very same per-tab record `session.json` persists -- url, title,
    /// pinned state, tab-group id. Reused rather than redefined so a
    /// reopened tab and a restored tab can never disagree about what a tab
    /// is: `BrowserWindowController.show(restoring:)` already knows how to
    /// turn one of these back into a live tab.
    let tab: SessionSnapshot.Tab
    /// Which profile's window it was closed from. ⇧⌘T only ever reopens an
    /// item belonging to the acting window's own profile -- reopening
    /// another profile's tab here would cross the boundary this whole
    /// browser exists to keep.
    let profileId: String
    /// The position it occupied in its window's tab strip.
    let index: Int
    let closedAt: Date
}

/// A whole window that was closed, with everything it was showing.
struct ClosedWindow: Codable, Equatable {
    let profileId: String
    let tabs: [SessionSnapshot.Tab]
    let groups: [SessionSnapshot.Group]
    let activeTabIndex: Int
    let frame: SessionSnapshot.WindowFrame?
    let closedAt: Date
}

/// One entry in the stack. A closed window is a single entry holding all of
/// its tabs, not one entry per tab -- so ⇧⌘T after closing a five-tab
/// window brings the window back once, rather than five presses rebuilding
/// it a tab at a time. That is how Chrome behaves and what the History >
/// Recently Closed menu needs to list.
enum ClosedItem: Equatable {
    case tab(ClosedTab)
    case window(ClosedWindow)

    var profileId: String {
        switch self {
        case .tab(let closed): return closed.profileId
        case .window(let closed): return closed.profileId
        }
    }

    var closedAt: Date {
        switch self {
        case .tab(let closed): return closed.closedAt
        case .window(let closed): return closed.closedAt
        }
    }

    /// What the History > Recently Closed menu shows for this entry.
    var menuTitle: String {
        switch self {
        case .tab(let closed):
            return closed.tab.title.isEmpty ? closed.tab.url : closed.tab.title
        case .window(let closed):
            let count = closed.tabs.count
            return count == 1 ? "Window (1 Tab)" : "Window (\(count) Tabs)"
        }
    }
}

/// The recently-closed stack behind ⇧⌘T and History > Recently Closed
/// (browser-n2j), newest first.
///
/// Pure value type: it decides what may be remembered, what order things
/// come back in, and what falls off the end. Where it is stored is
/// `ClosedItemStore`'s problem, and reopening is
/// `BrowserWindowController`'s.
struct ClosedItemStack: Equatable {
    /// Deep enough to cover "I have closed a dozen things since the one I
    /// want", shallow enough that the persisted file stays small and the
    /// Recently Closed menu stays a menu rather than a history window.
    /// Chrome's own stack is of this order; Safari's is shallower.
    static let defaultCapacity = 25

    let capacity: Int
    private(set) var items: [ClosedItem]

    init(capacity: Int = defaultCapacity, items: [ClosedItem] = []) {
        self.capacity = max(1, capacity)
        self.items = Array(items.prefix(self.capacity))
    }

    /// Records a closed tab or window, newest first. Returns false when the
    /// entry was refused, which is a normal outcome rather than an error.
    ///
    /// `isPrivate` has no default on purpose. **A private window's tabs must
    /// never be remembered** -- reopening one later, and especially after a
    /// relaunch from a file on disk, would hand back exactly the browsing
    /// private mode promises not to keep. Requiring the argument at every
    /// call site means a new caller cannot forget the question exists; the
    /// check lives here, at the single point of entry, rather than being
    /// repeated at each caller where one omission would leak.
    @discardableResult
    mutating func record(_ item: ClosedItem, isPrivate: Bool) -> Bool {
        guard !isPrivate, Self.isWorthRemembering(item) else { return false }
        items.insert(item, at: 0)
        if items.count > capacity {
            items.removeLast(items.count - capacity)
        }
        return true
    }

    /// Removes and returns the newest entry for `profileId` -- one press of
    /// ⇧⌘T. Entries belonging to other profiles are stepped over, not
    /// consumed, so pressing ⇧⌘T in one profile's window never eats another
    /// profile's history.
    mutating func popMostRecent(profileId: String) -> ClosedItem? {
        take(at: 0, profileId: profileId)
    }

    /// Removes and returns the entry at `index` **within this profile's own
    /// list** -- what picking a row out of the Recently Closed menu does.
    /// The index is into `recentItems(profileId:limit:)`, which is what the
    /// menu was built from, so the two can never disagree about which row a
    /// position means; an index that no longer exists returns nil rather
    /// than reopening whatever moved into its place.
    mutating func take(at index: Int, profileId: String) -> ClosedItem? {
        let positions = items.indices.filter { items[$0].profileId == profileId }
        guard positions.indices.contains(index) else { return nil }
        return items.remove(at: positions[index])
    }

    /// The newest entries for one profile, for the Recently Closed menu.
    func recentItems(profileId: String, limit: Int = 10) -> [ClosedItem] {
        Array(items.lazy.filter { $0.profileId == profileId }.prefix(limit))
    }

    mutating func removeAll() {
        items.removeAll()
    }

    /// A tab is worth remembering only if it has a real web address. A blank
    /// new tab or the start page has nothing to restore, and remembering it
    /// would make ⇧⌘T waste a press putting an empty tab back instead of
    /// the page the user actually meant.
    ///
    /// A window is worth remembering if any of its tabs is. Its tabs are
    /// then kept exactly as they were, blank ones included, so the window
    /// comes back looking like the window that was closed.
    private static func isWorthRemembering(_ item: ClosedItem) -> Bool {
        switch item {
        case .tab(let closed):
            return isRestorableURL(closed.tab.url)
        case .window(let closed):
            return closed.tabs.contains { isRestorableURL($0.url) }
        }
    }

    private static func isRestorableURL(_ url: String) -> Bool {
        url.hasPrefix("http://") || url.hasPrefix("https://")
    }
}

// MARK: - Persistence

/// Explicit, discriminated coding rather than the compiler's synthesized
/// enum form (`{"tab":{"_0":...}}`), because this is written to a file that
/// a later build has to keep reading. A named `kind` is legible when
/// debugging and leaves room for a third case.
extension ClosedItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, tab, window
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tab(let closed):
            try container.encode("tab", forKey: .kind)
            try container.encode(closed, forKey: .tab)
        case .window(let closed):
            try container.encode("window", forKey: .kind)
            try container.encode(closed, forKey: .window)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "tab":
            self = .tab(try container.decode(ClosedTab.self, forKey: .tab))
        case "window":
            self = .window(try container.decode(ClosedWindow.self, forKey: .window))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "unknown closed-item kind \"\(other)\""
            )
        }
    }
}

/// Wraps one entry so a single unreadable one is skipped instead of
/// throwing away the whole stack. An entry written by a future build with a
/// kind this build has never heard of is exactly that case, and losing
/// twenty-four good entries to it would be the worse outcome.
private struct LossyClosedItem: Decodable {
    let item: ClosedItem?

    init(from decoder: Decoder) throws {
        item = try? ClosedItem(from: decoder)
    }
}

extension ClosedItemStack: Codable {
    private enum CodingKeys: String, CodingKey {
        case items
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decodeIfPresent([LossyClosedItem].self, forKey: .items) ?? []
        self.init(items: decoded.compactMap(\.item))
    }
}
