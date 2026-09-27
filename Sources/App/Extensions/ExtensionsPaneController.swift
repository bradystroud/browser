import AppKit

/// Settings > Extensions: a pointer to the per-profile Extensions window,
/// which is where extensions are actually managed. The window stays the one
/// place for that, so the toolbar's "Manage Extensions…" and this pane never
/// disagree. Only added where the engine runs extensions.
final class ExtensionsPaneController: NSObject, SettingsPaneController {
    private static let margin: CGFloat = 12
    private static let height: CGFloat = 150

    let view = NSView(frame: NSRect(x: 0, y: 0, width: 536, height: ExtensionsPaneController.height))
    private let profilePopup = NSPopUpButton()

    func preferredContentHeight(forWidth width: CGFloat) -> CGFloat { Self.height }

    override init() {
        super.init()
        let margin = Self.margin
        let width = view.bounds.width
        var y = view.bounds.height - margin

        let header = NSTextField(wrappingLabelWithString:
            "Chrome extensions, from the Chrome Web Store or an unpacked folder. Each profile has its own extensions; private windows never run any.")
        header.textColor = .secondaryLabelColor
        y -= 34
        header.frame = NSRect(x: margin, y: y, width: width - margin * 2, height: 34)
        header.autoresizingMask = [.width, .minYMargin]
        view.addSubview(header)

        y -= 12 + 26
        let label = NSTextField(labelWithString: "Profile:")
        label.frame = NSRect(x: margin, y: y + 4, width: 60, height: 18)
        label.autoresizingMask = [.minYMargin]
        view.addSubview(label)
        profilePopup.frame = NSRect(x: margin + 64, y: y, width: 220, height: 26)
        profilePopup.autoresizingMask = [.minYMargin]
        view.addSubview(profilePopup)

        y -= 12 + 28
        let manage = NSButton(title: "Manage Extensions…", target: self, action: #selector(manage))
        manage.frame = NSRect(x: margin + 60, y: y, width: 180, height: 28)
        manage.autoresizingMask = [.minYMargin]
        view.addSubview(manage)

        reloadProfiles()
    }

    private func reloadProfiles() {
        profilePopup.removeAllItems()
        for profile in ProfileManager.shared.profiles {
            profilePopup.addItem(withTitle: profile.name)
            profilePopup.lastItem?.representedObject = profile.id
        }
        let key = (NSApp.mainWindow?.windowController as? BrowserWindowController).flatMap { $0.isPrivate ? nil : $0 }
        let current = key ?? WindowManager.shared.windowControllers.first { !$0.isPrivate }
        if let id = current?.profile.id, let index = profilePopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == id }) {
            profilePopup.selectItem(at: index)
        }
    }

    @objc private func manage() {
        guard let id = profilePopup.selectedItem?.representedObject as? String,
              let profile = ProfileManager.shared.profile(id: id) else { return }
        ExtensionsWindowManager.shared.show(for: profile)
    }
}
