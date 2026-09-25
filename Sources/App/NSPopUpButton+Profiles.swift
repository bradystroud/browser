import AppKit

extension NSPopUpButton {
    /// Refills this popup with every profile, each item carrying its Profile
    /// as `representedObject`, and selects `current` if it still exists --
    /// else the first profile. Returns the profile now selected, so a
    /// per-profile settings pane can keep its own selection across profile
    /// renames and deletions.
    func reloadProfiles(keeping current: Profile?) -> Profile? {
        let profiles = ProfileManager.shared.profiles
        removeAllItems()
        for profile in profiles {
            let item = NSMenuItem(title: profile.name, action: nil, keyEquivalent: "")
            item.representedObject = profile
            menu?.addItem(item)
        }

        let stillExists = current.flatMap { current in profiles.first { $0.id == current.id } }
        let toSelect = stillExists ?? profiles.first
        if let toSelect, let index = profiles.firstIndex(where: { $0.id == toSelect.id }) {
            selectItem(at: index)
        }
        return toSelect
    }
}
