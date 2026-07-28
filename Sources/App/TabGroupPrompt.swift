import AppKit

/// Presents the "New Tab Group…"/"Edit Tab Group" NSAlert (name field +
/// color palette) -- the same UI pattern as NewProfilePrompt, reused here
/// for a tab group instead of a profile. "Rename" and "Change Color" (the
/// group header's context menu items) both open this same combined dialog,
/// since it already lets you change either one; "Move to Group > New
/// Group…" uses it too, seeded with an empty name and an unused palette
/// color. `colorHex` draws from the same ProfileColorPalette profiles use
/// (see browser-rhi.1's scope: "colorHex from the existing profile
/// palette").
enum TabGroupPrompt {
    static func run(currentName: String, currentColorHex: String, isNew: Bool) -> (name: String, colorHex: String)? {
        let alert = NSAlert()
        alert.messageText = isNew ? "New Tab Group" : "Edit Tab Group"
        alert.informativeText = "Choose a name and color for the group."
        alert.addButton(withTitle: isNew ? "Create" : "Save")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 32, width: 260, height: 24))
        nameField.placeholderString = "Group name"
        nameField.stringValue = currentName

        let initialSelection = ProfileColorPalette.hexValues.firstIndex(of: currentColorHex) ?? 0
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
        return (trimmedName, swatchPicker.selectedHex)
    }
}
