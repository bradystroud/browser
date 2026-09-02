import AppKit
import LocalAuthentication

/// The "Cards" section of the Autofill Settings pane (browser-ojh.2) --
/// same profile-picker-then-table layout as PasswordsPaneController, and
/// the same Touch-ID-gated reveal pattern for the one thing that's
/// actually secret (the full card number; cardholder name/last-4/expiry
/// are shown in the table directly, same as PasswordsPaneController shows
/// site+username without gating).
final class CardsPaneController: NSObject, NSTableViewDataSource, NSTableViewDelegate, SettingsPaneController {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 536, height: 400))

    private let profilePopup = NSPopUpButton()
    private let cardsTableView = NSTableView()

    private var selectedProfile: Profile?
    private var cards: [StoredCardSummary] = []
    private var profileChangeObserver: NSObjectProtocol?

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
        let profiles = ProfileManager.shared.profiles
        profilePopup.removeAllItems()
        for profile in profiles {
            let item = NSMenuItem(title: profile.name, action: nil, keyEquivalent: "")
            item.representedObject = profile
            profilePopup.menu?.addItem(item)
        }

        let stillExists = selectedProfile.flatMap { current in profiles.first { $0.id == current.id } }
        let toSelect = stillExists ?? profiles.first
        if let toSelect, let index = profiles.firstIndex(where: { $0.id == toSelect.id }) {
            profilePopup.selectItem(at: index)
        }
        selectedProfile = toSelect
        loadCardsForSelectedProfile()
    }

    // MARK: - View setup

    private func setUpViews() {
        let margin: CGFloat = 12
        let rowGap: CGFloat = 10
        let headerHeight: CGFloat = 22
        let profileRowHeight: CGFloat = 28
        let buttonRowHeight: CGFloat = 28

        let headerLabel = NSTextField(labelWithString: "Cards")
        headerLabel.font = .boldSystemFont(ofSize: 13)
        headerLabel.frame = NSRect(x: margin, y: view.bounds.height - margin - headerHeight, width: view.bounds.width - margin * 2, height: headerHeight)
        headerLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(headerLabel)

        let revealButton = NSButton(title: "Reveal…", target: self, action: #selector(revealSelectedCard))
        revealButton.frame = NSRect(x: margin, y: margin, width: 90, height: buttonRowHeight)
        revealButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        view.addSubview(revealButton)

        let deleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteSelectedCard))
        deleteButton.frame = NSRect(x: margin + 94, y: margin, width: 70, height: buttonRowHeight)
        deleteButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        view.addSubview(deleteButton)

        let profileRowY = margin + buttonRowHeight + rowGap
        let profileLabel = NSTextField(labelWithString: "Profile:")
        profileLabel.frame = NSRect(x: margin, y: profileRowY + 6, width: 60, height: 20)
        profileLabel.autoresizingMask = [.maxXMargin, .maxYMargin]
        view.addSubview(profileLabel)

        profilePopup.frame = NSRect(x: margin + 64, y: profileRowY, width: 200, height: profileRowHeight)
        profilePopup.autoresizingMask = [.maxXMargin, .maxYMargin]
        profilePopup.target = self
        profilePopup.action = #selector(profileSelectionChanged)
        view.addSubview(profilePopup)

        let scrollTop = view.bounds.height - margin - headerHeight - rowGap
        let scrollBottom = profileRowY + profileRowHeight + rowGap
        let scrollView = NSScrollView(frame: NSRect(x: margin, y: scrollBottom, width: view.bounds.width - margin * 2, height: max(0, scrollTop - scrollBottom)))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true

        let nameColumn = NSTableColumn(identifier: .init("cardholderName"))
        nameColumn.title = "Name"
        nameColumn.width = 220

        let numberColumn = NSTableColumn(identifier: .init("last4"))
        numberColumn.title = "Card"
        numberColumn.width = 120

        let expiryColumn = NSTableColumn(identifier: .init("expiry"))
        expiryColumn.title = "Expires"
        expiryColumn.width = 100

        cardsTableView.addTableColumn(nameColumn)
        cardsTableView.addTableColumn(numberColumn)
        cardsTableView.addTableColumn(expiryColumn)
        cardsTableView.dataSource = self
        cardsTableView.delegate = self
        ListAppearance.apply(to: cardsTableView, in: scrollView)
        scrollView.documentView = cardsTableView
        view.addSubview(scrollView)
    }

    // MARK: - Data

    private func loadCardsForSelectedProfile() {
        guard let profile = selectedProfile else {
            cards = []
            cardsTableView.reloadData()
            return
        }
        cards = CardStore.allCards(profileName: profile.name)
            .sorted { $0.cardholderName == $1.cardholderName ? $0.last4 < $1.last4 : $0.cardholderName < $1.cardholderName }
        cardsTableView.reloadData()
    }

    // MARK: - Actions

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

        let context = LAContext()
        var evaluationError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &evaluationError) else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Can't Verify Identity"
            alert.informativeText = "Touch ID or your account password isn't available for verification on this Mac, so this card can't be revealed."
            alert.runModal()
            return
        }

        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "reveal the saved card ending \(card.last4)"
        ) { [weak self] success, _ in
            DispatchQueue.main.async {
                guard success, let self,
                      let number = CardStore.cardNumber(profileName: profile.name, id: card.id)
                else {
                    return
                }
                self.showRevealedCard(number, for: card)
            }
        }
    }

    private func showRevealedCard(_ number: String, for card: StoredCardSummary) {
        let alert = NSAlert()
        alert.messageText = "\(card.cardholderName) -- expires \(String(format: "%02d", card.expMonth))/\(card.expYear)"
        alert.informativeText = number
        alert.addButton(withTitle: "Copy Number")
        alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(number, forType: .string)
        }
    }

    @objc private func deleteSelectedCard() {
        let row = cardsTableView.selectedRow
        guard let profile = selectedProfile, cards.indices.contains(row) else { return }
        let card = cards[row]

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete Saved Card?"
        alert.informativeText = "The saved card for \(card.cardholderName) ending \(card.last4) will be removed."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        CardStore.delete(profileName: profile.name, id: card.id)
        loadCardsForSelectedProfile()
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        cards.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard cards.indices.contains(row), let columnIdentifier = tableColumn?.identifier else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cardCell.\(columnIdentifier.rawValue)")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField ?? NSTextField(labelWithString: "")
        cell.identifier = identifier
        let card = cards[row]
        switch columnIdentifier.rawValue {
        case "cardholderName":
            cell.stringValue = card.cardholderName
        case "last4":
            cell.stringValue = "····\(card.last4)"
        case "expiry":
            cell.stringValue = String(format: "%02d/%d", card.expMonth, card.expYear)
        default:
            cell.stringValue = ""
        }
        return cell
    }
}
