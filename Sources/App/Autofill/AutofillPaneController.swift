import AppKit

/// The "Autofill" tab of the Settings window (browser-ojh.2) -- an inner
/// NSTabView with three sections: Passwords (browser-ojh.1's existing
/// PasswordsPaneController, unchanged, just relocated under this wrapper
/// instead of being its own top-level Settings tab), Cards, and Addresses.
/// SettingsWindowController hosts this one controller instead of hosting
/// PasswordsPaneController directly -- see that file's own updated doc
/// comment.
final class AutofillPaneController: NSObject {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 536, height: 400))

    private let passwordsPane = PasswordsPaneController()
    private let cardsPane = CardsPaneController()
    private let addressesPane = AddressesPaneController()
    private let tabView = NSTabView()

    override init() {
        super.init()
        setUpViews()
    }

    func reload() {
        passwordsPane.reload()
        cardsPane.reload()
        addressesPane.reload()
    }

    private func setUpViews() {
        tabView.frame = view.bounds
        tabView.autoresizingMask = [.width, .height]

        let passwordsItem = NSTabViewItem(identifier: "autofill-passwords")
        passwordsItem.label = "Passwords"
        passwordsItem.view = passwordsPane.view

        let cardsItem = NSTabViewItem(identifier: "autofill-cards")
        cardsItem.label = "Cards"
        cardsItem.view = cardsPane.view

        let addressesItem = NSTabViewItem(identifier: "autofill-addresses")
        addressesItem.label = "Addresses"
        addressesItem.view = addressesPane.view

        tabView.addTabViewItem(passwordsItem)
        tabView.addTabViewItem(cardsItem)
        tabView.addTabViewItem(addressesItem)
        view.addSubview(tabView)
    }
}
