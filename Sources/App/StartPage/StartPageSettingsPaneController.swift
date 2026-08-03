import AppKit

/// The "Start Page" pane of the Settings window (see SettingsWindowController,
/// which hosts this alongside the other panes in an NSTabView) -- reached
/// both from the menu/⌘, and from the start page's own gear button (a
/// same-document URL-fragment click intercepted in Tab.engineTabDidChangeURL,
/// see StartPageRenderer.settingsFragment). Per-profile: a profile picker,
/// a background color swatch picker (rendered as a simple gradient -- see
/// StartPageRenderer), and toggles for each section. Every change saves
/// immediately via StartPageSettingsStore.
final class StartPageSettingsPaneController: NSObject, SettingsPaneController {
    private static let margin: CGFloat = 12
    private static let rowGap: CGFloat = 10
    private static let headerHeight: CGFloat = 22
    private static let profileRowHeight: CGFloat = 28
    private static let checkboxRowHeight: CGFloat = 20
    private static let swatchLabelHeight: CGFloat = 16
    private static let swatchRowHeight: CGFloat = ColorSwatchPicker.swatchDiameter

    /// This pane's natural content height, computed from the same
    /// constants setUpViews lays out with -- see
    /// GeneralPaneController.preferredContentHeight's doc comment for why
    /// this pane needs its own accurate value instead of
    /// SettingsPaneController's generic table-filler default.
    static let preferredContentHeight: CGFloat =
        margin + headerHeight + rowGap + profileRowHeight + rowGap + checkboxRowHeight + 6 + checkboxRowHeight
            + rowGap + swatchLabelHeight + 6 + swatchRowHeight + margin
    var preferredContentHeight: CGFloat { Self.preferredContentHeight }

    let view = NSView(frame: NSRect(x: 0, y: 0, width: 536, height: StartPageSettingsPaneController.preferredContentHeight))

    private let profilePopup = NSPopUpButton()
    private let favoritesCheckbox = NSButton(checkboxWithTitle: "Show Favorites", target: nil, action: nil)
    private let frequentlyVisitedCheckbox = NSButton(checkboxWithTitle: "Show Frequently Visited", target: nil, action: nil)
    private var swatchPicker: ColorSwatchPicker?
    private let swatchContainer = NSView()

    private var selectedProfile: Profile?

    override init() {
        super.init()
        setUpViews()
        reload()
    }

    /// Repopulates the profile picker from ProfileManager, preserving the
    /// current selection if it still exists, then reloads that profile's
    /// settings.
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
        loadSettingsForSelectedProfile()
    }

    // MARK: - View setup

    private func setUpViews() {
        let margin = Self.margin
        let rowGap = Self.rowGap
        let headerHeight = Self.headerHeight
        let profileRowHeight = Self.profileRowHeight
        let checkboxRowHeight = Self.checkboxRowHeight
        let swatchLabelHeight = Self.swatchLabelHeight
        let swatchRowHeight = Self.swatchRowHeight

        let headerLabel = NSTextField(labelWithString: "Start Page")
        headerLabel.font = .boldSystemFont(ofSize: 13)
        headerLabel.frame = NSRect(
            x: margin,
            y: view.bounds.height - margin - headerHeight,
            width: view.bounds.width - margin * 2,
            height: headerHeight
        )
        headerLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(headerLabel)

        // Top-down from here, each row pinned to the top (.minYMargin) so
        // extra height the window picks up collects below the color
        // swatches instead of pushing this content toward the bottom edge.
        let profileRowY = headerLabel.frame.minY - rowGap - profileRowHeight
        let profileLabel = NSTextField(labelWithString: "Profile:")
        profileLabel.frame = NSRect(x: margin, y: profileRowY + 6, width: 60, height: 20)
        profileLabel.autoresizingMask = [.maxXMargin, .minYMargin]
        view.addSubview(profileLabel)

        profilePopup.frame = NSRect(x: margin + 64, y: profileRowY, width: 200, height: profileRowHeight)
        profilePopup.autoresizingMask = [.maxXMargin, .minYMargin]
        profilePopup.target = self
        profilePopup.action = #selector(profileSelectionChanged)
        view.addSubview(profilePopup)

        let checkbox1Y = profileRowY - rowGap - checkboxRowHeight
        favoritesCheckbox.target = self
        favoritesCheckbox.action = #selector(toggleChanged)
        favoritesCheckbox.frame = NSRect(x: margin, y: checkbox1Y, width: 260, height: checkboxRowHeight)
        favoritesCheckbox.autoresizingMask = [.maxXMargin, .minYMargin]
        view.addSubview(favoritesCheckbox)

        let checkbox2Y = checkbox1Y - 6 - checkboxRowHeight
        frequentlyVisitedCheckbox.target = self
        frequentlyVisitedCheckbox.action = #selector(toggleChanged)
        frequentlyVisitedCheckbox.frame = NSRect(x: margin, y: checkbox2Y, width: 260, height: checkboxRowHeight)
        frequentlyVisitedCheckbox.autoresizingMask = [.maxXMargin, .minYMargin]
        view.addSubview(frequentlyVisitedCheckbox)

        // The label sits above the swatches it describes (it used to sit
        // below them -- same inverted-order bug as General's popup label).
        let swatchLabelY = checkbox2Y - rowGap - swatchLabelHeight
        let swatchLabel = NSTextField(labelWithString: "Background color:")
        swatchLabel.frame = NSRect(x: margin, y: swatchLabelY, width: 200, height: swatchLabelHeight)
        swatchLabel.autoresizingMask = [.maxXMargin, .minYMargin]
        view.addSubview(swatchLabel)

        let swatchContainerY = swatchLabelY - 6 - swatchRowHeight
        swatchContainer.frame = NSRect(x: margin, y: swatchContainerY, width: view.bounds.width - margin * 2, height: swatchRowHeight)
        swatchContainer.autoresizingMask = [.width, .minYMargin]
        view.addSubview(swatchContainer)
    }

    // MARK: - Data

    private func loadSettingsForSelectedProfile() {
        swatchPicker?.removeFromSuperview()
        swatchPicker = nil

        guard let profile = selectedProfile else {
            favoritesCheckbox.isEnabled = false
            frequentlyVisitedCheckbox.isEnabled = false
            return
        }
        favoritesCheckbox.isEnabled = true
        frequentlyVisitedCheckbox.isEnabled = true

        let settings = StartPageSettingsStore.load(forProfileId: profile.id)
        favoritesCheckbox.state = settings.showFavorites ? .on : .off
        frequentlyVisitedCheckbox.state = settings.showFrequentlyVisited ? .on : .off

        let initialSelection = ProfileColorPalette.hexValues.firstIndex(of: settings.backgroundColorHex) ?? 0
        let picker = ColorSwatchPicker(hexValues: ProfileColorPalette.hexValues, initialSelection: initialSelection)
        picker.frame.origin = .zero
        picker.onSelectionChanged = { [weak self] in self?.saveCurrentSettings() }
        swatchContainer.addSubview(picker)
        swatchPicker = picker
    }

    private func saveCurrentSettings() {
        guard let profile = selectedProfile else { return }
        let settings = StartPageSettings(
            backgroundColorHex: swatchPicker?.selectedHex ?? ProfileColorPalette.hexValues[7],
            showFavorites: favoritesCheckbox.state == .on,
            showFrequentlyVisited: frequentlyVisitedCheckbox.state == .on
        )
        StartPageSettingsStore.save(settings, forProfileId: profile.id)
    }

    // MARK: - Actions

    @objc private func profileSelectionChanged() {
        selectedProfile = profilePopup.selectedItem?.representedObject as? Profile
        loadSettingsForSelectedProfile()
    }

    @objc private func toggleChanged() {
        saveCurrentSettings()
    }
}
