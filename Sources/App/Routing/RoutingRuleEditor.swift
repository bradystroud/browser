import AppKit

/// Presents an add/edit dialog for a single RoutingRule -- URL contains
/// (the simplest field, listed first), domain glob, URL regex, source app
/// (picker of currently-running apps' bundle IDs, plus free-text entry for
/// any other bundle ID), and target profile. Mirrors NewProfilePrompt's
/// NSAlert-accessory-view pattern.
enum RoutingRuleEditor {
    /// `existingRule` nil means "add"; non-nil means "edit" (its `id` is
    /// preserved so RoutingRulesStore.updateRule can find it).
    @discardableResult
    static func run(existingRule: RoutingRule?) -> RoutingRule? {
        let alert = NSAlert()
        alert.messageText = existingRule == nil ? "New Link Rule" : "Edit Link Rule"
        alert.informativeText = "Every field you fill in must match for this rule to apply (AND). Leave a field blank to skip it."
        let saveButton = alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let fieldWidth: CGFloat = 280
        let rowHeight: CGFloat = 24
        let labelHeight: CGFloat = 16
        let errorHeight: CGFloat = 14
        let rowGap: CGFloat = 6
        let groupGap: CGFloat = 10

        var y: CGFloat = 0
        let accessory = NSView(frame: .zero)

        func addLabel(_ text: String, y: CGFloat) {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: 0, y: y, width: fieldWidth, height: labelHeight)
            accessory.addSubview(label)
        }

        // Built bottom-up (y = 0 at the bottom), then the whole stack is
        // flipped into top-down reading order by the accessory's final height.
        let openInPopup = NSPopUpButton(frame: NSRect(x: 0, y: y, width: fieldWidth, height: rowHeight))
        for (title, openIn) in openInChoices {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = openIn?.rawValue
            openInPopup.menu?.addItem(item)
        }
        accessory.addSubview(openInPopup)
        addLabel("Open links from other apps in", y: y + rowHeight)
        y += rowHeight + labelHeight + groupGap

        let profilePopup = NSPopUpButton(frame: NSRect(x: 0, y: y, width: fieldWidth, height: rowHeight))
        for profile in ProfileManager.shared.profiles {
            let item = NSMenuItem(title: profile.name, action: nil, keyEquivalent: "")
            item.representedObject = profile
            profilePopup.menu?.addItem(item)
        }
        accessory.addSubview(profilePopup)
        addLabel("Target profile", y: y + rowHeight)
        y += rowHeight + labelHeight + groupGap

        let sourceAppCombo = NSComboBox(frame: NSRect(x: 0, y: y, width: fieldWidth, height: rowHeight))
        sourceAppCombo.completes = true
        let runningApps = RunningApplicationPicker.currentEntries()
        for entry in runningApps {
            sourceAppCombo.addItem(withObjectValue: comboDisplayString(for: entry))
        }
        accessory.addSubview(sourceAppCombo)
        addLabel("Source app (optional -- pick a running app, or type any bundle ID)", y: y + rowHeight)
        y += rowHeight + labelHeight + groupGap

        // The regex field's error row is always reserved (fixed layout, no
        // reflow) but only shows text when the current pattern is invalid.
        let regexErrorLabel = NSTextField(labelWithString: "")
        regexErrorLabel.font = .systemFont(ofSize: 11)
        regexErrorLabel.textColor = .systemRed
        regexErrorLabel.frame = NSRect(x: 0, y: y, width: fieldWidth, height: errorHeight)
        accessory.addSubview(regexErrorLabel)
        y += errorHeight + 2

        let regexField = NSTextField(frame: NSRect(x: 0, y: y, width: fieldWidth, height: rowHeight))
        regexField.placeholderString = "^https://mail\\."
        regexField.wantsLayer = true
        accessory.addSubview(regexField)
        addLabel("URL regex (optional)", y: y + rowHeight)
        y += rowHeight + labelHeight + groupGap

        let domainField = NSTextField(frame: NSRect(x: 0, y: y, width: fieldWidth, height: rowHeight))
        domainField.placeholderString = "*.example.com or example.com"
        accessory.addSubview(domainField)
        addLabel("Domain glob (optional)", y: y + rowHeight)
        y += rowHeight + labelHeight + groupGap

        let containsField = NSTextField(frame: NSRect(x: 0, y: y, width: fieldWidth, height: rowHeight))
        containsField.placeholderString = "ssw"
        accessory.addSubview(containsField)
        addLabel("URL contains (optional -- simplest option, matches any part of the link)", y: y + rowHeight)
        y += rowHeight + labelHeight

        accessory.frame = NSRect(x: 0, y: 0, width: fieldWidth, height: y)

        // Live regex validation -- refuse to save an uncompilable pattern
        // rather than silently turning it into a never-match rule (the
        // failure mode that motivated this: browser-hbr, glob syntax typed
        // into this field with zero feedback). The delegate is kept alive
        // for the alert's lifetime via this local `validator` reference.
        let validator = RegexFieldValidator(
            regexField: regexField,
            errorLabel: regexErrorLabel,
            saveButton: saveButton
        )
        regexField.delegate = validator

        // Prefill for edit.
        if let rule = existingRule {
            containsField.stringValue = rule.match.urlContains ?? ""
            domainField.stringValue = rule.match.domainGlob ?? ""
            regexField.stringValue = rule.match.urlRegex ?? ""
            if let bundleId = rule.match.sourceBundleIds?.first {
                if let entry = runningApps.first(where: { $0.bundleIdentifier == bundleId }) {
                    sourceAppCombo.stringValue = comboDisplayString(for: entry)
                } else {
                    sourceAppCombo.stringValue = bundleId
                }
            }
            if let index = ProfileManager.shared.profiles.firstIndex(where: { $0.id == rule.action.profileId }) {
                profilePopup.selectItem(at: index)
            }
            if let index = openInChoices.firstIndex(where: { $0.openIn == rule.action.openIn }) {
                openInPopup.selectItem(at: index)
            }
        }
        validator.revalidate()

        alert.accessoryView = accessory
        alert.window.initialFirstResponder = containsField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }

        // Belt and braces: the Save button is disabled while invalid, but
        // don't trust button state alone against e.g. a stray Return
        // keypress -- re-check here too.
        guard validator.isValid else { return nil }

        guard let selectedProfile = profilePopup.selectedItem?.representedObject as? Profile else { return nil }

        let urlContains = nonEmpty(containsField.stringValue)
        let domainGlob = nonEmpty(domainField.stringValue)
        let urlRegex = nonEmpty(regexField.stringValue)
        let sourceBundleId = resolveBundleId(from: sourceAppCombo.stringValue, runningApps: runningApps)

        let match = RoutingRule.Match(
            urlContains: urlContains,
            domainGlob: domainGlob,
            urlRegex: urlRegex,
            sourceBundleIds: sourceBundleId.map { [$0] }
        )
        let openIn = (openInPopup.selectedItem?.representedObject as? String).flatMap(RoutingRule.OpenIn.init(rawValue:))
        let action = RoutingRule.Action(profileId: selectedProfile.id, openIn: openIn)

        if let existingRule {
            return RoutingRule(id: existingRule.id, match: match, action: action)
        }
        return RoutingRule(match: match, action: action)
    }

    /// nil follows the global "little window" setting in the Routing pane.
    private static let openInChoices: [(title: String, openIn: RoutingRule.OpenIn?)] = [
        ("Follow the global setting", nil),
        ("A browser tab", .browser),
        ("A little window", .littleWindow),
    ]

    private static func comboDisplayString(for entry: RunningApplicationPicker.Entry) -> String {
        "\(entry.displayName) — \(entry.bundleIdentifier)"
    }

    /// The combo box shows "DisplayName — bundle.id" for picked entries but
    /// accepts arbitrary typed text too; a typed value that doesn't match the
    /// "— " separator format is assumed to already be a bare bundle ID.
    private static func resolveBundleId(from text: String, runningApps: [RunningApplicationPicker.Entry]) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let separatorRange = trimmed.range(of: " — ") {
            return String(trimmed[separatorRange.upperBound...])
        }
        return trimmed
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Validates the URL-regex field as-you-type: an empty field is valid (the
/// field is optional); a non-empty field must compile as an
/// NSRegularExpression. Invalid input gets a red field border, a short error
/// message, and disables the alert's Save button -- so an uncompilable
/// pattern can never be saved as a rule that silently never matches (see
/// browser-hbr). Input containing `*` that fails to compile is very likely
/// someone reaching for glob/wildcard syntax (Finicky/shell-style `*ssw*`),
/// so that case gets a more specific hint pointing at the "URL contains"
/// field instead of a generic "invalid regex" message.
private final class RegexFieldValidator: NSObject, NSTextFieldDelegate {
    private let regexField: NSTextField
    private let errorLabel: NSTextField
    private let saveButton: NSButton

    private(set) var isValid = true

    init(regexField: NSTextField, errorLabel: NSTextField, saveButton: NSButton) {
        self.regexField = regexField
        self.errorLabel = errorLabel
        self.saveButton = saveButton
    }

    func controlTextDidChange(_ notification: Notification) {
        revalidate()
    }

    func revalidate() {
        let pattern = regexField.stringValue
        let message = Self.validationMessage(for: pattern)
        isValid = (message == nil)

        errorLabel.stringValue = message ?? ""
        saveButton.isEnabled = isValid

        regexField.layer?.borderWidth = isValid ? 0 : 1.5
        regexField.layer?.borderColor = NSColor.systemRed.cgColor
        regexField.layer?.cornerRadius = 3
    }

    /// nil = valid (empty field, or a pattern that compiles).
    private static func validationMessage(for pattern: String) -> String? {
        guard !pattern.isEmpty else { return nil }
        guard (try? NSRegularExpression(pattern: pattern)) == nil else { return nil }

        if let hint = globHint(for: pattern) {
            return hint
        }
        return "Invalid regular expression"
    }

    /// A pattern containing `*` that still fails to compile is almost
    /// certainly glob/wildcard syntax, not a deliberately malformed regex --
    /// `*` alone (nothing to repeat) is one of the most common
    /// NSRegularExpression compile failures for exactly this reason. Strips
    /// leading/trailing `*` to recover the plain substring someone actually
    /// meant (e.g. `*ssw*` -> `ssw`) for the suggested "URL contains" value.
    private static func globHint(for pattern: String) -> String? {
        guard pattern.contains("*") else { return nil }
        let stripped = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
        if stripped.isEmpty {
            return "Looks like a pattern — try “URL contains” instead."
        }
        return "Looks like a pattern — use “URL contains” with “\(stripped)”, or regex: \(NSRegularExpression.escapedPattern(for: stripped))"
    }
}
