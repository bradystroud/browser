import AppKit
import UniformTypeIdentifiers

/// The "Start Page" pane of the Settings window (see SettingsWindowController)
/// -- reached both from the menu/⌘, and from the start page's own gear
/// button (a same-document URL-fragment click intercepted in
/// Tab.engineTabDidChangeURL, see StartPageRenderer.settingsFragment).
/// Per-profile: a profile picker, toggles for each section, a background
/// color swatch picker (rendered as a simple gradient -- see
/// StartPageRenderer), and an optional background image that replaces that
/// color (browser-1wo). Every change saves immediately via
/// StartPageSettingsStore and re-renders that profile's already-open start
/// pages (StartPageSettingsCoordinator.refreshOpenStartPages).
final class StartPageSettingsPaneController: NSObject, SettingsPaneController {
    private static let imageRowHeight: CGFloat = 48
    private static let imageThumbnailWidth: CGFloat = 76

    private let form = SettingsForm()
    func preferredContentHeight(forWidth width: CGFloat) -> CGFloat { form.fittingHeight }

    let view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 320))

    private let profilePopup = NSPopUpButton()
    private let favoritesCheckbox = NSButton(checkboxWithTitle: "Show Favorites", target: nil, action: nil)
    private let frequentlyVisitedCheckbox = NSButton(checkboxWithTitle: "Show Frequently Visited", target: nil, action: nil)
    private let bookmarksCheckbox = NSButton(checkboxWithTitle: "Show Bookmarks", target: nil, action: nil)
    private var swatchPicker: ColorSwatchPicker?
    private let swatchContainer = NSView()
    private let imageThumbnail = NSImageView()
    private let chooseImageButton = NSButton(title: "Choose Picture…", target: nil, action: nil)
    private let removeImageButton = NSButton(title: "Remove", target: nil, action: nil)
    private let imageStatusLabel = SettingsForm.footnote()

    private var selectedProfile: Profile?

    /// Mirrors whether the selected profile currently has a background image
    /// on disk, so saveCurrentSettings (shared by every control in this pane)
    /// writes the right backgroundImageFileName without re-hitting the file
    /// system on each checkbox toggle.
    private var hasBackgroundImage = false

    override init() {
        super.init()
        setUpViews()
        reload()
    }

    /// Repopulates the profile picker from ProfileManager, preserving the
    /// current selection if it still exists, then reloads that profile's
    /// settings.
    func reload() {
        selectedProfile = profilePopup.reloadProfiles(keeping: selectedProfile)
        loadSettingsForSelectedProfile()
    }

    // MARK: - View setup

    private func setUpViews() {
        profilePopup.target = self
        profilePopup.action = #selector(profileSelectionChanged)
        form.addRow("Profile:", profilePopup)

        form.beginSection()
        for checkbox in [favoritesCheckbox, frequentlyVisitedCheckbox, bookmarksCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(toggleChanged)
        }
        form.addRow("Sections:", favoritesCheckbox)
        form.addRow(nil, frequentlyVisitedCheckbox)
        form.addRow(nil, bookmarksCheckbox)

        form.beginSection()
        // The swatch picker is rebuilt for each profile (see
        // loadSettingsForSelectedProfile), so the grid holds a fixed-size
        // container for it rather than the picker itself.
        let swatchCount = CGFloat(ProfileColorPalette.hexValues.count)
        let swatchWidth = swatchCount * ColorSwatchPicker.swatchDiameter + max(swatchCount - 1, 0) * ColorSwatchPicker.spacing
        swatchContainer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            swatchContainer.widthAnchor.constraint(equalToConstant: min(swatchWidth, SettingsForm.controlColumnWidth)),
            swatchContainer.heightAnchor.constraint(equalToConstant: ColorSwatchPicker.swatchDiameter),
        ])
        let swatchRow = form.addRow("Background color:", swatchContainer)
        swatchRow.rowAlignment = .none
        swatchRow.yPlacement = .center

        imageThumbnail.imageScaling = .scaleProportionallyUpOrDown
        imageThumbnail.wantsLayer = true
        imageThumbnail.layer?.cornerRadius = 6
        imageThumbnail.layer?.masksToBounds = true
        imageThumbnail.layer?.borderWidth = 1
        imageThumbnail.layer?.borderColor = NSColor.separatorColor.cgColor
        imageThumbnail.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageThumbnail.widthAnchor.constraint(equalToConstant: Self.imageThumbnailWidth),
            imageThumbnail.heightAnchor.constraint(equalToConstant: Self.imageRowHeight),
        ])
        chooseImageButton.bezelStyle = .rounded
        chooseImageButton.target = self
        chooseImageButton.action = #selector(chooseBackgroundImage)
        removeImageButton.bezelStyle = .rounded
        removeImageButton.target = self
        removeImageButton.action = #selector(removeBackgroundImage)
        form.addRow(SettingsForm.label("Background picture:"), [imageThumbnail, chooseImageButton, removeImageButton])
        form.addFootnote(imageStatusLabel)

        form.install(in: view)
    }

    // MARK: - Data

    private func loadSettingsForSelectedProfile() {
        swatchPicker?.removeFromSuperview()
        swatchPicker = nil

        guard let profile = selectedProfile else {
            favoritesCheckbox.isEnabled = false
            frequentlyVisitedCheckbox.isEnabled = false
            bookmarksCheckbox.isEnabled = false
            chooseImageButton.isEnabled = false
            hasBackgroundImage = false
            updateBackgroundImageControls(forProfileId: nil)
            return
        }
        favoritesCheckbox.isEnabled = true
        frequentlyVisitedCheckbox.isEnabled = true
        bookmarksCheckbox.isEnabled = true
        chooseImageButton.isEnabled = true

        let settings = StartPageSettingsStore.load(forProfileId: profile.id)
        favoritesCheckbox.state = settings.showFavorites ? .on : .off
        frequentlyVisitedCheckbox.state = settings.showFrequentlyVisited ? .on : .off
        bookmarksCheckbox.state = settings.showBookmarks ? .on : .off
        // Trusts the file, not just the setting: a background recorded in
        // startpage.json whose file has since been deleted (or was never
        // written) shows as "None" here, matching what the start page itself
        // falls back to rendering.
        hasBackgroundImage = settings.backgroundImageFileName != nil
            && StartPageBackgroundImageStore.image(forProfileId: profile.id) != nil
        updateBackgroundImageControls(forProfileId: profile.id)

        let initialSelection = ProfileColorPalette.hexValues.firstIndex(of: settings.backgroundColorHex) ?? 0
        let picker = ColorSwatchPicker(hexValues: ProfileColorPalette.hexValues, initialSelection: initialSelection)
        picker.frame.origin = .zero
        picker.onSelectionChanged = { [weak self] in self?.saveCurrentSettings() }
        swatchContainer.addSubview(picker)
        swatchPicker = picker
    }

    private func updateBackgroundImageControls(forProfileId profileId: String?) {
        let image = hasBackgroundImage ? profileId.flatMap {
            StartPageBackgroundImageStore.image(forProfileId: $0)
        } : nil
        imageThumbnail.image = image
        removeImageButton.isEnabled = hasBackgroundImage
        imageStatusLabel.stringValue = hasBackgroundImage
            ? "The picture replaces the background colour above."
            : "None — the background colour above is used."
        invalidateContentHeight()
    }

    private func saveCurrentSettings() {
        guard let profile = selectedProfile else { return }
        let settings = StartPageSettings(
            backgroundColorHex: swatchPicker?.selectedHex ?? ProfileColorPalette.hexValues[7],
            showFavorites: favoritesCheckbox.state == .on,
            showFrequentlyVisited: frequentlyVisitedCheckbox.state == .on,
            showBookmarks: bookmarksCheckbox.state == .on,
            backgroundImageFileName: hasBackgroundImage ? StartPageBackgroundImageStore.fileName : nil
        )
        StartPageSettingsStore.save(settings, forProfileId: profile.id)
        StartPageSettingsCoordinator.refreshOpenStartPages(forProfileId: profile.id)
    }

    // MARK: - Actions

    @objc private func profileSelectionChanged() {
        selectedProfile = profilePopup.selectedItem?.representedObject as? Profile
        loadSettingsForSelectedProfile()
    }

    @objc private func toggleChanged() {
        saveCurrentSettings()
    }

    @objc private func chooseBackgroundImage() {
        guard let profile = selectedProfile else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Choose"
        panel.message = "Choose a background picture for \(profile.name)'s start page"
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }

        guard StartPageBackgroundImageStore.install(from: sourceURL, forProfileId: profile.id) else {
            let alert = NSAlert()
            alert.messageText = "Couldn’t use that picture"
            alert.informativeText = "\(sourceURL.lastPathComponent) couldn’t be read as an image, so the background is unchanged."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        hasBackgroundImage = true
        // Saves before refreshing the controls: the thumbnail is read back
        // from the copy this just wrote, not from the file the user picked.
        saveCurrentSettings()
        updateBackgroundImageControls(forProfileId: profile.id)
    }

    @objc private func removeBackgroundImage() {
        guard let profile = selectedProfile else { return }
        StartPageBackgroundImageStore.remove(forProfileId: profile.id)
        hasBackgroundImage = false
        saveCurrentSettings()
        updateBackgroundImageControls(forProfileId: profile.id)
    }
}
