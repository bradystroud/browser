import AppKit

/// Settings > Extensions: a pointer to the per-profile Extensions window,
/// which is where extensions are actually managed. The window stays the one
/// place for that, so the toolbar's "Manage Extensions…" and this pane never
/// disagree. Only added where the engine runs extensions.
final class ExtensionsPaneController: NSObject, SettingsPaneController {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 150))
    private let form = SettingsForm()
    private let profilePopup = NSPopUpButton()

    func preferredContentHeight(forWidth width: CGFloat) -> CGFloat { form.fittingHeight }

    override init() {
        super.init()
        form.addRow("Profile:", profilePopup)
        let manage = NSButton(title: "Manage Extensions…", target: self, action: #selector(manage))
        manage.bezelStyle = .rounded
        form.addRow(nil, manage)
        form.addFootnote(SettingsForm.footnote(
            "Chrome extensions, from the Chrome Web Store or an unpacked folder. Each profile has its own extensions; private windows never run any."))
        form.install(in: view)
        profilePopup.nextKeyView = manage
        manage.nextKeyView = profilePopup

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
