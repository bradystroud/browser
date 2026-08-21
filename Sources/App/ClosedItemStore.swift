import Foundation

/// Reads/writes the recently-closed stack (browser-n2j) as JSON in the same
/// directory as `session.json` -- normally `~/Library/Application
/// Support/Browser/`, fully redirected by an explicit `--profiles-root`
/// launch (browser-1rp), so an isolated test launch can never record into,
/// or reopen from, Brady's real browsing.
///
/// Deliberately the same shape as SessionStore, which persists the same kind
/// of data next to it: debounced saves for the frequent triggers, and a
/// synchronous `saveNow()` at quit where there is no time to wait out a
/// debounce. The decision about *what* may be remembered belongs to
/// `ClosedItemStack` (SessionCore) and is not repeated here.
final class ClosedItemStore {
    static let shared = ClosedItemStore()

    private let fileURL: URL
    private let debounceInterval: TimeInterval = 1.0
    private var pendingSaveWorkItem: DispatchWorkItem?
    private var stack: ClosedItemStack

    private init() {
        let dir = URL(fileURLWithPath: CommandLineArgs.sessionAndProfilesMetadataDirectory())
        fileURL = dir.appendingPathComponent("closed-items.json")
        // A missing or unreadable file is the normal first-launch state, not
        // an error: an empty stack simply means ⇧⌘T has nothing to give back
        // yet. A file damaged beyond one bad entry is treated the same way --
        // see ClosedItemStack's own decoding, which already skips individual
        // entries it cannot read rather than losing the rest.
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(ClosedItemStack.self, from: data) {
            stack = decoded
        } else {
            stack = ClosedItemStack()
        }
    }

    /// Records a closed tab or window. `isPrivate` is passed straight
    /// through to `ClosedItemStack.record`, which is where the refusal
    /// actually happens -- see that method for why the check lives at one
    /// point of entry rather than at each caller.
    func record(_ item: ClosedItem, isPrivate: Bool) {
        guard stack.record(item, isPrivate: isPrivate) else { return }
        scheduleSave()
    }

    /// One press of ⇧⌘T: removes and returns the newest entry for this
    /// profile, or nil when there is nothing left to reopen.
    func takeMostRecent(profileId: String) -> ClosedItem? {
        guard let item = stack.popMostRecent(profileId: profileId) else { return nil }
        scheduleSave()
        return item
    }

    /// For the History > Recently Closed menu. Reading does not consume:
    /// picking an entry from the menu goes through `take(at:profileId:)`.
    func recentItems(profileId: String, limit: Int = 10) -> [ClosedItem] {
        stack.recentItems(profileId: profileId, limit: limit)
    }

    /// Takes the entry the user picked out of the Recently Closed menu,
    /// identified by its position in `recentItems(profileId:limit:)`.
    ///
    /// Matching by position rather than by holding onto the value is
    /// deliberate: the menu is rebuilt from `recentItems` each time it is
    /// opened, so the index the user clicked is always an index into the
    /// list they are looking at. Re-reading it here rather than trusting a
    /// captured copy means a stack that changed while the menu was open
    /// cannot reopen the wrong thing -- it reopens whatever is now at that
    /// position, or nothing.
    func take(at index: Int, profileId: String) -> ClosedItem? {
        guard let item = stack.take(at: index, profileId: profileId) else { return nil }
        scheduleSave()
        return item
    }

    /// Clears everything, for "Clear History" -- a reading of history that
    /// left the last twenty-five closed tabs sitting in a file beside it
    /// would not be a clear at all.
    func clear() {
        stack.removeAll()
        saveNow()
    }

    private func scheduleSave() {
        pendingSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    /// Immediate, synchronous write -- used at quit, where there is no time
    /// to wait out the debounce. Without it, a tab closed in the last second
    /// before ⌘Q would not be in the file the next launch reads.
    func saveNow() {
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        guard let data = try? JSONEncoder().encode(stack) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
