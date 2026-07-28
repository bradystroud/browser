import AppKit

/// A modal sheet for adding/editing a saved address (browser-ojh.2) --
/// used by AddressesPaneController. Not a popover like the save prompts
/// (this needs real text-entry fields and isn't tied to a page event), so
/// a plain NSWindow shown as a sheet is the simplest fit, same idiom
/// NSSavePanel already uses elsewhere in this app (BrowserWindow.
/// exportAsPDF).
final class AddressFormSheetController: NSObject {
    private let window: NSWindow
    private var fields: [String: NSTextField] = [:]
    private var completion: ((StoredAddress?) -> Void)?
    private let existingId: String

    /// `existing` is nil for "add a new address"; passing one in edits it
    /// in place (same id preserved on save).
    init(existing: StoredAddress?) {
        existingId = existing?.id ?? UUID().uuidString
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 340),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = existing == nil ? "Add Address" : "Edit Address"
        super.init()
        setUpViews(existing: existing)
    }

    private static let fieldOrder: [(key: String, label: String)] = [
        ("fullName", "Full Name"),
        ("streetAddress", "Street Address"),
        ("addressLine2", "Address Line 2"),
        ("city", "City"),
        ("state", "State/Province"),
        ("postalCode", "Postal Code"),
        ("country", "Country"),
        ("phone", "Phone"),
        ("email", "Email"),
    ]

    private func setUpViews(existing: StoredAddress?) {
        guard let contentView = window.contentView else { return }
        let margin: CGFloat = 16
        let rowHeight: CGFloat = 24
        let labelWidth: CGFloat = 110
        var y = contentView.bounds.height - margin - rowHeight

        let existingValues: [String: String] = existing.map {
            [
                "fullName": $0.fullName, "streetAddress": $0.streetAddress, "addressLine2": $0.addressLine2,
                "city": $0.city, "state": $0.state, "postalCode": $0.postalCode,
                "country": $0.country, "phone": $0.phone, "email": $0.email,
            ]
        } ?? [:]

        for (key, label) in Self.fieldOrder {
            let labelField = NSTextField(labelWithString: label)
            labelField.frame = NSRect(x: margin, y: y + 3, width: labelWidth, height: 18)
            labelField.alignment = .right
            labelField.autoresizingMask = [.maxXMargin, .minYMargin]
            contentView.addSubview(labelField)

            let textField = NSTextField(frame: NSRect(x: margin + labelWidth + 8, y: y, width: contentView.bounds.width - margin * 2 - labelWidth - 8, height: rowHeight))
            textField.stringValue = existingValues[key] ?? ""
            textField.autoresizingMask = [.width, .minYMargin]
            contentView.addSubview(textField)
            fields[key] = textField

            y -= rowHeight + 6
        }

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancelButton.bezelStyle = .rounded
        cancelButton.frame = NSRect(x: contentView.bounds.width - margin - 80 - 8 - 80, y: margin, width: 80, height: 28)
        cancelButton.autoresizingMask = [.minXMargin, .maxYMargin]
        contentView.addSubview(cancelButton)

        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.frame = NSRect(x: contentView.bounds.width - margin - 80, y: margin, width: 80, height: 28)
        saveButton.autoresizingMask = [.minXMargin, .maxYMargin]
        contentView.addSubview(saveButton)
    }

    /// Shows the sheet on `parentWindow`; `completion` is called exactly
    /// once, with the entered address (or nil if cancelled).
    func show(in parentWindow: NSWindow, completion: @escaping (StoredAddress?) -> Void) {
        self.completion = completion
        parentWindow.beginSheet(window) { [weak self] _ in
            // Keep self alive until the sheet's own callback fires --
            // beginSheet doesn't otherwise retain this controller.
            _ = self
        }
    }

    @objc private func saveTapped() {
        let address = StoredAddress(
            id: existingId,
            fullName: fields["fullName"]?.stringValue ?? "",
            streetAddress: fields["streetAddress"]?.stringValue ?? "",
            addressLine2: fields["addressLine2"]?.stringValue ?? "",
            city: fields["city"]?.stringValue ?? "",
            state: fields["state"]?.stringValue ?? "",
            postalCode: fields["postalCode"]?.stringValue ?? "",
            country: fields["country"]?.stringValue ?? "",
            phone: fields["phone"]?.stringValue ?? "",
            email: fields["email"]?.stringValue ?? ""
        )
        window.sheetParent?.endSheet(window)
        completion?(address)
    }

    @objc private func cancelTapped() {
        window.sheetParent?.endSheet(window)
        completion?(nil)
    }
}
