import AppKit

/// Presents an add/edit dialog for a single RoutingRule -- domain glob, URL
/// regex, source app (picker of currently-running apps' bundle IDs, plus
/// free-text entry for any other bundle ID), and target profile. Mirrors
/// NewProfilePrompt's NSAlert-accessory-view pattern.
enum RoutingRuleEditor {
    /// `existingRule` nil means "add"; non-nil means "edit" (its `id` is
    /// preserved so RoutingRulesStore.updateRule can find it).
    @discardableResult
    static func run(existingRule: RoutingRule?) -> RoutingRule? {
        let alert = NSAlert()
        alert.messageText = existingRule == nil ? "New Routing Rule" : "Edit Routing Rule"
        alert.informativeText = "Every field you fill in must match for this rule to apply (AND). Leave a field blank to skip it."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let fieldWidth: CGFloat = 280
        let rowHeight: CGFloat = 24
        let labelHeight: CGFloat = 16
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

        let regexField = NSTextField(frame: NSRect(x: 0, y: y, width: fieldWidth, height: rowHeight))
        regexField.placeholderString = "^https://mail\\."
        accessory.addSubview(regexField)
        addLabel("URL regex (optional)", y: y + rowHeight)
        y += rowHeight + labelHeight + groupGap

        let domainField = NSTextField(frame: NSRect(x: 0, y: y, width: fieldWidth, height: rowHeight))
        domainField.placeholderString = "*.example.com or example.com"
        accessory.addSubview(domainField)
        addLabel("Domain glob (optional)", y: y + rowHeight)
        y += rowHeight + labelHeight

        accessory.frame = NSRect(x: 0, y: 0, width: fieldWidth, height: y)

        // Prefill for edit.
        if let rule = existingRule {
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
        }

        alert.accessoryView = accessory
        alert.window.initialFirstResponder = domainField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }

        guard let selectedProfile = profilePopup.selectedItem?.representedObject as? Profile else { return nil }

        let domainGlob = nonEmpty(domainField.stringValue)
        let urlRegex = nonEmpty(regexField.stringValue)
        let sourceBundleId = resolveBundleId(from: sourceAppCombo.stringValue, runningApps: runningApps)

        let match = RoutingRule.Match(
            domainGlob: domainGlob,
            urlRegex: urlRegex,
            sourceBundleIds: sourceBundleId.map { [$0] }
        )
        let action = RoutingRule.Action(profileId: selectedProfile.id)

        if let existingRule {
            return RoutingRule(id: existingRule.id, match: match, action: action)
        }
        return RoutingRule(match: match, action: action)
    }

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
