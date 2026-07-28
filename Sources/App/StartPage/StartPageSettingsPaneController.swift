import AppKit

/// The "Start Page" pane of the Settings window (see SettingsWindowController,
/// which hosts this alongside the other panes in an NSTabView) -- reached
/// both from the menu/⌘, and from the start page's own gear button (a
/// same-document URL-fragment click intercepted in Tab.engineTabDidChangeURL,
/// see StartPageRenderer.settingsFragment). Per-profile: a profile picker,
/// a background color swatch picker (rendered as a simple gradient -- see
/// StartPageRenderer), and toggles for each section. Every change saves
/// immediately via StartPageSettingsStore.
final class StartPageSettingsPaneController: NSObject {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 536, height: 400))

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
        let margin: CGFloat = 12
        let rowGap: CGFloat = 10
        let headerHeight: CGFloat = 22
        let profileRowHeight: CGFloat = 28
        let checkboxRowHeight: CGFloat = 20
        let swatchRowHeight: CGFloat = ColorSwatchPicker.swatchDiameter

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

        // Bottom-up from here, mirroring the other panes' layout style.
        let profileRowY: CGFloat = margin
        let profileLabel = NSTextField(labelWithString: "Profile:")
        profileLabel.frame = NSRect(x: margin, y: profileRowY + 6, width: 60, height: 20)
        profileLabel.autoresizingMask = [.maxXMargin, .maxYMargin]
        view.addSubview(profileLabel)

        profilePopup.frame = NSRect(x: margin + 64, y: profileRowY, width: 200, height: profileRowHeight)
        profilePopup.autoresizingMask = [.maxXMargin, .maxYMargin]
        profilePopup.target = self
        profilePopup.action = #selector(profileSelectionChanged)
        view.addSubview(profilePopup)

        let checkbox1Y = profileRowY + profileRowHeight + rowGap
        favoritesCheckbox.target = self
        favoritesCheckbox.action = #selector(toggleChanged)
        favoritesCheckbox.frame = NSRect(x: margin, y: checkbox1Y, width: 260, height: checkboxRowHeight)
        favoritesCheckbox.autoresizingMask = [.maxXMargin, .maxYMargin]
        view.addSubview(favoritesCheckbox)

        let checkbox2Y = checkbox1Y + checkboxRowHeight + 6
        frequentlyVisitedCheckbox.target = self
        frequentlyVisitedCheckbox.action = #selector(toggleChanged)
        frequentlyVisitedCheckbox.frame = NSRect(x: margin, y: checkbox2Y, width: 260, height: checkboxRowHeight)
        frequentlyVisitedCheckbox.autoresizingMask = [.maxXMargin, .maxYMargin]
        view.addSubview(frequentlyVisitedCheckbox)

        let swatchLabelY = checkbox2Y + checkboxRowHeight + rowGap
        let swatchLabel = NSTextField(labelWithString: "Background color:")
        swatchLabel.frame = NSRect(x: margin, y: swatchLabelY, width: 200, height: 16)
        swatchLabel.autoresizingMask = [.maxXMargin, .maxYMargin]
        view.addSubview(swatchLabel)

        swatchContainer.frame = NSRect(x: margin, y: swatchLabelY + 16 + 6, width: view.bounds.width - margin * 2, height: swatchRowHeight)
        swatchContainer.autoresizingMask = [.width, .maxYMargin]
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

        let settings = StartPageSettingsStore.load(forProfileName: profile.name)
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
        StartPageSettingsStore.save(settings, forProfileName: profile.name)
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
