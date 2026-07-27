import AppKit

/// Presents the "New Profile…" / "Edit Profile…" NSAlert (name field + color
/// palette) and creates or updates the profile in ProfileManager if the user
/// confirms. `existingProfile` nil means "create"; non-nil means "edit
/// in place" (rename + recolor, preserving id) -- same dialog, same
/// validation, used both by the Profiles menu's "New Profile…" item and by
/// the Settings window's Profiles pane (create and edit both).
enum NewProfilePrompt {
    @discardableResult
    static func run(existingProfile: Profile? = nil) -> Profile? {
        let alert = NSAlert()
        alert.messageText = existingProfile == nil ? "New Profile" : "Edit Profile"
        alert.informativeText = "Choose a name and color for the profile."
        alert.addButton(withTitle: existingProfile == nil ? "Create" : "Save")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 32, width: 260, height: 24))
        nameField.placeholderString = "Profile name"
        nameField.stringValue = existingProfile?.name ?? ""

        let initialSelection = existingProfile.flatMap { ProfileColorPalette.hexValues.firstIndex(of: $0.colorHex) } ?? 0
        let swatchPicker = ColorSwatchPicker(hexValues: ProfileColorPalette.hexValues, initialSelection: initialSelection)
        swatchPicker.frame.origin = NSPoint(x: 0, y: 0)

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 60))
        accessory.addSubview(nameField)
        accessory.addSubview(swatchPicker)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = nameField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }

        let trimmedName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        let collision = ProfileManager.shared.profile(named: trimmedName)
        let nameTakenByAnotherProfile = collision != nil && collision?.id != existingProfile?.id
        guard !nameTakenByAnotherProfile else {
            let errorAlert = NSAlert()
            errorAlert.messageText = "A profile named \"\(trimmedName)\" already exists."
            errorAlert.runModal()
            return nil
        }

        if let existingProfile {
            ProfileManager.shared.updateProfile(id: existingProfile.id, name: trimmedName, colorHex: swatchPicker.selectedHex)
            return ProfileManager.shared.profile(id: existingProfile.id)
        }
        return ProfileManager.shared.createProfile(name: trimmedName, colorHex: swatchPicker.selectedHex)
    }
}
