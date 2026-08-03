import AppKit

/// The "General" pane of the Settings window (see SettingsWindowController,
/// which hosts this alongside the other panes in an NSTabView) -- currently
/// just the omnibox display-mode preference (browser-0y1, Brady's ask).
/// Global, not per-profile (see OmniboxDisplayPreference's own doc comment
/// for why), so unlike the other panes there's no profile picker here.
final class GeneralPaneController: NSObject, SettingsPaneController {
    private static let margin: CGFloat = 12
    private static let headerHeight: CGFloat = 22
    private static let rowHeight: CGFloat = 28
    private static let labelHeight: CGFloat = 20
    private static let helpHeight: CGFloat = 48
    private static let rowGap: CGFloat = 12

    /// This pane's natural content height, computed from the same
    /// constants setUpViews lays out with so the two can never drift apart
    /// -- SettingsWindowController resizes the Settings window to this
    /// whenever General becomes the selected tab (unlike the table-based
    /// panes, General has no scrollable content to stretch into whatever
    /// height it's given, so it needs its own accurate size instead of
    /// sharing SettingsPaneController's generic default).
    static let preferredContentHeight: CGFloat =
        margin + headerHeight + rowGap + labelHeight + 6 + rowHeight + rowGap + helpHeight + margin
    var preferredContentHeight: CGFloat { Self.preferredContentHeight }

    let view = NSView(frame: NSRect(x: 0, y: 0, width: 536, height: GeneralPaneController.preferredContentHeight))

    private let modePopup = NSPopUpButton()
    private let helpLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }()

    override init() {
        super.init()
        setUpViews()
        reload()
    }

    func reload() {
        let current = OmniboxDisplayPreference.current
        if let index = OmniboxDisplayMode.allCases.firstIndex(of: current) {
            modePopup.selectItem(at: index)
        }
        updateHelpText(for: current)
    }

    private func setUpViews() {
        let margin = Self.margin
        let headerHeight = Self.headerHeight
        let rowHeight = Self.rowHeight
        let labelHeight = Self.labelHeight
        let helpHeight = Self.helpHeight
        let rowGap = Self.rowGap

        let headerLabel = NSTextField(labelWithString: "General")
        headerLabel.font = .boldSystemFont(ofSize: 13)
        headerLabel.frame = NSRect(
            x: margin,
            y: view.bounds.height - margin - headerHeight,
            width: view.bounds.width - margin * 2,
            height: headerHeight
        )
        headerLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(headerLabel)

        // Top-down from here: the label sits above the popup it describes,
        // which sits above the help text explaining the current selection
        // -- all pinned to the top (.minYMargin) so any extra height the
        // window picks up collects below the help text rather than pushing
        // this content toward the bottom edge.
        let rowLabelY = headerLabel.frame.minY - rowGap - labelHeight
        let rowLabel = NSTextField(labelWithString: "When not focused, the address bar shows:")
        rowLabel.frame = NSRect(x: margin, y: rowLabelY, width: view.bounds.width - margin * 2, height: labelHeight)
        rowLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(rowLabel)

        let popupY = rowLabelY - 6 - rowHeight
        modePopup.frame = NSRect(x: margin, y: popupY, width: 200, height: rowHeight)
        modePopup.autoresizingMask = [.maxXMargin, .minYMargin]
        for mode in OmniboxDisplayMode.allCases {
            modePopup.menu?.addItem(NSMenuItem(title: mode.title, action: nil, keyEquivalent: ""))
        }
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        view.addSubview(modePopup)

        let helpY = popupY - rowGap - helpHeight
        helpLabel.frame = NSRect(x: margin, y: helpY, width: view.bounds.width - margin * 2, height: helpHeight)
        helpLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(helpLabel)
    }

    private func updateHelpText(for mode: OmniboxDisplayMode) {
        switch mode {
        case .domainOnly:
            helpLabel.stringValue = "Shows just the site's domain (e.g. \u{201c}example.com\u{201d}) until you click the address bar or press \u{2318}L, which always shows the full URL for editing."
        case .pageTitle:
            helpLabel.stringValue = "Shows the current page's title until you click the address bar or press \u{2318}L, which always shows the full URL for editing."
        case .fullURL:
            helpLabel.stringValue = "Shows the full URL, with the \u{201c}https://\u{201d} prefix hidden for a cleaner look. \u{201c}http://\u{201d} always stays visible, so an insecure site is never disguised as secure."
        }
    }

    @objc private func modeChanged() {
        let index = modePopup.indexOfSelectedItem
        guard OmniboxDisplayMode.allCases.indices.contains(index) else { return }
        let mode = OmniboxDisplayMode.allCases[index]
        OmniboxDisplayPreference.current = mode
        updateHelpText(for: mode)
    }
}
