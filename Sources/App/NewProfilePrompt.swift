import AppKit

/// Presents the "New Profile…" NSAlert (name field + color palette) and
/// creates the profile in ProfileManager if the user confirms.
enum NewProfilePrompt {
    @discardableResult
    static func run() -> Profile? {
        let alert = NSAlert()
        alert.messageText = "New Profile"
        alert.informativeText = "Choose a name and color for the new profile."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 32, width: 260, height: 24))
        nameField.placeholderString = "Profile name"

        let swatchPicker = ColorSwatchPicker(hexValues: ProfileColorPalette.hexValues)
        swatchPicker.frame.origin = NSPoint(x: 0, y: 0)

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 60))
        accessory.addSubview(nameField)
        accessory.addSubview(swatchPicker)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = nameField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }

        let trimmedName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, ProfileManager.shared.profile(named: trimmedName) == nil else {
            if trimmedName.isEmpty {
                return nil
            }
            let errorAlert = NSAlert()
            errorAlert.messageText = "A profile named \"\(trimmedName)\" already exists."
            errorAlert.runModal()
            return nil
        }

        return ProfileManager.shared.createProfile(name: trimmedName, colorHex: swatchPicker.selectedHex)
    }
}
