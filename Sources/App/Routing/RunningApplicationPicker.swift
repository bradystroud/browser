import AppKit

/// Lists currently-running regular (Dock-visible) apps as candidates for a
/// rule's source-app field, so the rules editor can offer a picker instead of
/// requiring the user to know a bundle identifier by heart. Snapshotted once
/// per editor open, not live -- the running-app set at rule-creation time is
/// just a convenience list, not something the rule depends on afterwards.
enum RunningApplicationPicker {
    struct Entry {
        let bundleIdentifier: String
        let displayName: String
    }

    static func currentEntries() -> [Entry] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> Entry? in
                guard let bundleId = app.bundleIdentifier else { return nil }
                return Entry(bundleIdentifier: bundleId, displayName: app.localizedName ?? bundleId)
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}
