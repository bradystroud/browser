import AppKit

/// The "General" pane of the Settings window (see SettingsWindowController,
/// which hosts this alongside the other panes in an NSTabView) -- currently
/// just the omnibox display-mode preference (browser-0y1, Brady's ask).
/// Global, not per-profile (see OmniboxDisplayPreference's own doc comment
/// for why), so unlike the other panes there's no profile picker here.
final class GeneralPaneController: NSObject {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 536, height: 400))

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
        let margin: CGFloat = 12
        let headerHeight: CGFloat = 22
        let rowHeight: CGFloat = 28

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

        // Bottom-up from here, mirroring the other panes' layout style
        // (see StartPageSettingsPaneController.setUpViews).
        let helpY: CGFloat = margin
        helpLabel.frame = NSRect(x: margin, y: helpY, width: view.bounds.width - margin * 2, height: 48)
        helpLabel.autoresizingMask = [.width, .maxYMargin]
        view.addSubview(helpLabel)

        let rowY = helpY + 48 + 8
        let rowLabel = NSTextField(labelWithString: "When not focused, the address bar shows:")
        rowLabel.frame = NSRect(x: margin, y: rowY + 6, width: view.bounds.width - margin * 2, height: 20)
        rowLabel.autoresizingMask = [.width, .maxYMargin]
        view.addSubview(rowLabel)

        let popupY = rowY + 20 + 8
        modePopup.frame = NSRect(x: margin, y: popupY, width: 200, height: rowHeight)
        modePopup.autoresizingMask = [.maxXMargin, .maxYMargin]
        for mode in OmniboxDisplayMode.allCases {
            modePopup.menu?.addItem(NSMenuItem(title: mode.title, action: nil, keyEquivalent: ""))
        }
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        view.addSubview(modePopup)
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
