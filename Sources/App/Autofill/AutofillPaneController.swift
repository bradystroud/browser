import AppKit

/// The "Autofill" pane of the Settings window: saved cards, addresses and
/// the email suggestions, one at a time under a segmented control. Saved
/// passwords have their own pane (PasswordsPaneController) -- they are the
/// section people open most, and a pane of their own keeps them one click
/// away rather than two, the way Safari's settings do.
///
/// A segmented control rather than three more toolbar panes: the three are
/// one feature (what the browser fills into forms), and a toolbar of twelve
/// would no longer fit a settings window.
final class AutofillPaneController: NSObject, SettingsPaneController {
    private static let margin: CGFloat = 20
    private static let controlGap: CGFloat = 12

    let view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 400))

    private let cardsPane = CardsPaneController()
    private let addressesPane = AddressesPaneController()
    private let emailsPane = EmailAutofillPaneController()
    private let sectionControl = NSSegmentedControl(
        labels: ["Cards", "Addresses", "Emails"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let container = NSView()

    /// In segment order.
    private static let sectionNames = ["cards", "addresses", "emails"]

    private var sectionPanes: [SettingsPaneController] { [cardsPane, addressesPane, emailsPane] }

    override init() {
        super.init()
        setUpViews()
        showSection(at: 0)
    }

    /// Tall enough for the tallest section, so switching sections never
    /// squeezes one list below what another had.
    func preferredContentHeight(forWidth width: CGFloat) -> CGFloat {
        let sectionHeight = sectionPanes.map { $0.preferredContentHeight(forWidth: width) }.max() ?? 400
        return (Self.margin + sectionControl.frame.height + Self.controlGap + sectionHeight).rounded(.up)
    }

    func reload() {
        cardsPane.reload()
        addressesPane.reload()
        emailsPane.reload()
    }

    /// The section a `--show-settings-tab autofill:<section>` names, or nil.
    /// Accepts the short names ("cards") and the identifiers the sections
    /// had as inner tabs ("autofill-cards").
    static func sectionName(from identifier: String) -> String? {
        let name = identifier.hasPrefix("autofill-") ? String(identifier.dropFirst("autofill-".count)) : identifier
        return sectionNames.contains(name) ? name : nil
    }

    /// Entry point for `--show-settings-tab autofill:<section>` (see
    /// SettingsWindowController.showTab), so an agent can screenshot a
    /// section directly.
    func selectSubTab(identifier: String) {
        guard let name = Self.sectionName(from: identifier), let index = Self.sectionNames.firstIndex(of: name) else {
            NSLog("Autofill settings has no section named '%@'", identifier)
            return
        }
        showSection(at: index)
    }

    private func setUpViews() {
        sectionControl.target = self
        sectionControl.action = #selector(sectionChanged)
        sectionControl.sizeToFit()
        let controlSize = sectionControl.frame.size
        sectionControl.frame = NSRect(
            x: ((view.bounds.width - controlSize.width) / 2).rounded(),
            y: view.bounds.height - Self.margin - controlSize.height,
            width: controlSize.width,
            height: controlSize.height
        )
        sectionControl.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        view.addSubview(sectionControl)

        container.frame = NSRect(
            x: 0,
            y: 0,
            width: view.bounds.width,
            height: sectionControl.frame.minY - Self.controlGap
        )
        container.autoresizingMask = [.width, .height]
        view.addSubview(container)
    }

    @objc private func sectionChanged() {
        showSection(at: sectionControl.selectedSegment)
    }

    private func showSection(at index: Int) {
        guard sectionPanes.indices.contains(index) else { return }
        sectionControl.selectedSegment = index
        let paneView = sectionPanes[index].view
        guard paneView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        paneView.frame = container.bounds
        paneView.autoresizingMask = [.width, .height]
        container.addSubview(paneView)
    }
}
