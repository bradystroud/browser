import AppKit

/// The "Cards" section of the Autofill Settings pane (browser-ojh.2) --
/// same profile-picker-then-table layout as PasswordsPaneController, and
/// the same Touch-ID-gated reveal pattern for the one thing that's
/// actually secret (the full card number; cardholder name/last-4/expiry
/// are shown in the table directly, same as PasswordsPaneController shows
/// site+username without gating).
final class CardsPaneController: NSObject, NSTableViewDataSource, NSTableViewDelegate, SettingsPaneController {
    /// Sits under the Autofill pane's section control, which already
    /// provides the space above it.
    static let topMargin: CGFloat = 8

    let view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 400))

    private let profilePopup = NSPopUpButton()
    private let cardsTableView = NSTableView()
    private lazy var listButtons = SettingsTablePane.removeOnlyButtons(target: self, action: #selector(listButtonClicked))
    private lazy var revealButton = NSButton(title: "Reveal…", target: self, action: #selector(revealSelectedCard))
    private let form = SettingsForm()

    private var selectedProfile: Profile?
    private var cards: [StoredCardSummary] = []
    private var profileChangeObserver: NSObjectProtocol?

    func preferredContentHeight(forWidth width: CGFloat) -> CGFloat {
        SettingsTablePane.preferredHeight(form: form, topMargin: Self.topMargin)
    }

    override init() {
        super.init()
        setUpViews()
        reload()
        profileChangeObserver = NotificationCenter.default.addObserver(
            forName: .profileManagerDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
    }

    func reload() {
        selectedProfile = profilePopup.reloadProfiles(keeping: selectedProfile)
        loadCardsForSelectedProfile()
    }

    // MARK: - View setup

    private func setUpViews() {
        profilePopup.target = self
        profilePopup.action = #selector(profileSelectionChanged)
        form.addRow("Profile:", profilePopup)

        let nameColumn = NSTableColumn(identifier: .init("cardholderName"))
        nameColumn.title = "Name"
        nameColumn.width = 280

        let numberColumn = NSTableColumn(identifier: .init("last4"))
        numberColumn.title = "Card"
        numberColumn.width = 140

        let expiryColumn = NSTableColumn(identifier: .init("expiry"))
        expiryColumn.title = "Expires"
        expiryColumn.width = 120

        cardsTableView.addTableColumn(nameColumn)
        cardsTableView.addTableColumn(numberColumn)
        cardsTableView.addTableColumn(expiryColumn)
        cardsTableView.dataSource = self
        cardsTableView.delegate = self

        SettingsTablePane.install(
            in: view,
            topMargin: Self.topMargin,
            form: form,
            table: cardsTableView,
            listButtons: listButtons,
            trailingButtons: [revealButton]
        )
        updateSelectionDependentControls()
    }

    // MARK: - Data

    private func loadCardsForSelectedProfile() {
        defer { updateSelectionDependentControls() }
        guard let profile = selectedProfile else {
            cards = []
            cardsTableView.reloadData()
            return
        }
        cards = CardStore.allCards(profileName: profile.name)
            .sorted { $0.cardholderName == $1.cardholderName ? $0.last4 < $1.last4 : $0.cardholderName < $1.cardholderName }
        cardsTableView.reloadData()
    }

    private func updateSelectionDependentControls() {
        let hasSelection = cards.indices.contains(cardsTableView.selectedRow)
        listButtons.setEnabled(hasSelection, forSegment: 0)
        revealButton.isEnabled = hasSelection
    }

    // MARK: - Actions

    @objc private func listButtonClicked() {
        deleteSelectedCard()
    }

    @objc private func profileSelectionChanged() {
        selectedProfile = profilePopup.selectedItem?.representedObject as? Profile
        loadCardsForSelectedProfile()
    }

    /// Gates the one path in this pane that can show a saved card's actual
    /// number -- a fresh LocalAuthentication check, same pattern as
    /// PasswordsPaneController.revealSelectedPassword. CardStore.cardNumber
    /// itself performs no such check; this is the only caller.
    @objc private func revealSelectedCard() {
        let row = cardsTableView.selectedRow
        guard let profile = selectedProfile, cards.indices.contains(row) else { return }
        let card = cards[row]

        SecretReveal.authenticate(toReveal: "card", reason: "reveal the saved card ending \(card.last4)") {
            guard let number = CardStore.cardNumber(profileName: profile.name, id: card.id) else { return }
            SecretReveal.present(
                number,
                title: "\(card.cardholderName) -- expires \(String(format: "%02d", card.expMonth))/\(card.expYear)",
                copyButtonTitle: "Copy Number"
            )
        }
    }

    @objc private func deleteSelectedCard() {
        let row = cardsTableView.selectedRow
        guard let profile = selectedProfile, cards.indices.contains(row) else { return }
        let card = cards[row]

        guard NSAlert.confirmDestructive(
            message: "Delete Saved Card?",
            informativeText: "The saved card for \(card.cardholderName) ending \(card.last4) will be removed.",
            confirmTitle: "Delete"
        ) else { return }

        CardStore.delete(profileName: profile.name, id: card.id)
        loadCardsForSelectedProfile()
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        cards.count
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelectionDependentControls()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard cards.indices.contains(row), let columnIdentifier = tableColumn?.identifier else { return nil }
        let card = cards[row]
        let text: String
        switch columnIdentifier.rawValue {
        case "cardholderName":
            text = card.cardholderName
        case "last4":
            text = "····\(card.last4)"
        case "expiry":
            text = String(format: "%02d/%d", card.expMonth, card.expYear)
        default:
            text = ""
        }
        return ListAppearance.textCell(in: tableView, identifier: "cardCell.\(columnIdentifier.rawValue)", text: text)
    }
}
