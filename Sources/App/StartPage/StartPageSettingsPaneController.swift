import AppKit
import UniformTypeIdentifiers

/// The "Start Page" pane of the Settings window (see SettingsWindowController,
/// which hosts this alongside the other panes in an NSTabView) -- reached
/// both from the menu/⌘, and from the start page's own gear button (a
/// same-document URL-fragment click intercepted in Tab.engineTabDidChangeURL,
/// see StartPageRenderer.settingsFragment). Per-profile: a profile picker,
/// a background color swatch picker (rendered as a simple gradient -- see
/// StartPageRenderer), an optional background image that replaces that color
/// (browser-1wo), and toggles for each section. Every change saves immediately
/// via StartPageSettingsStore and re-renders that profile's already-open start
/// pages (StartPageSettingsCoordinator.refreshOpenStartPages).
final class StartPageSettingsPaneController: NSObject, SettingsPaneController {
    private static let margin: CGFloat = 12
    private static let rowGap: CGFloat = 10
    private static let headerHeight: CGFloat = 22
    private static let profileRowHeight: CGFloat = 28
    private static let checkboxRowHeight: CGFloat = 20
    private static let swatchLabelHeight: CGFloat = 16
    private static let swatchRowHeight: CGFloat = ColorSwatchPicker.swatchDiameter
    private static let imageRowHeight: CGFloat = 48
    private static let imageThumbnailWidth: CGFloat = 76

    /// This pane's natural content height, computed from the same
    /// constants setUpViews lays out with -- it has no table to stretch, so
    /// it needs its own accurate value instead of SettingsPaneController's
    /// generic table-filler default.
    static let preferredContentHeight: CGFloat =
        margin + headerHeight + rowGap + profileRowHeight + rowGap + checkboxRowHeight + 6 + checkboxRowHeight
            + rowGap + swatchLabelHeight + 6 + swatchRowHeight
            + rowGap + swatchLabelHeight + 6 + imageRowHeight + margin
    func preferredContentHeight(forWidth width: CGFloat) -> CGFloat { Self.preferredContentHeight }

    let view = NSView(frame: NSRect(x: 0, y: 0, width: 536, height: StartPageSettingsPaneController.preferredContentHeight))

    private let profilePopup = NSPopUpButton()
    private let favoritesCheckbox = NSButton(checkboxWithTitle: "Show Favorites", target: nil, action: nil)
    private let frequentlyVisitedCheckbox = NSButton(checkboxWithTitle: "Show Frequently Visited", target: nil, action: nil)
    private var swatchPicker: ColorSwatchPicker?
    private let swatchContainer = NSView()
    private let imageThumbnail = NSImageView()
    private let chooseImageButton = NSButton(title: "Choose Picture…", target: nil, action: nil)
    private let removeImageButton = NSButton(title: "Remove", target: nil, action: nil)
    private let imageStatusLabel = NSTextField(labelWithString: "")

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

        let imageLabelY = swatchContainerY - rowGap - swatchLabelHeight
        let imageLabel = NSTextField(labelWithString: "Background picture:")
        imageLabel.frame = NSRect(x: margin, y: imageLabelY, width: 200, height: swatchLabelHeight)
        imageLabel.autoresizingMask = [.maxXMargin, .minYMargin]
        view.addSubview(imageLabel)

        let imageRowY = imageLabelY - 6 - Self.imageRowHeight
        imageThumbnail.frame = NSRect(x: margin, y: imageRowY, width: Self.imageThumbnailWidth, height: Self.imageRowHeight)
        imageThumbnail.autoresizingMask = [.maxXMargin, .minYMargin]
        imageThumbnail.imageScaling = .scaleProportionallyUpOrDown
        imageThumbnail.wantsLayer = true
        imageThumbnail.layer?.cornerRadius = 6
        imageThumbnail.layer?.masksToBounds = true
        imageThumbnail.layer?.borderWidth = 1
        imageThumbnail.layer?.borderColor = NSColor.separatorColor.cgColor
        view.addSubview(imageThumbnail)

        let buttonsX = margin + Self.imageThumbnailWidth + 12
        chooseImageButton.bezelStyle = .rounded
        chooseImageButton.target = self
        chooseImageButton.action = #selector(chooseBackgroundImage)
        chooseImageButton.frame = NSRect(x: buttonsX, y: imageRowY + Self.imageRowHeight - 24, width: 140, height: 24)
        chooseImageButton.autoresizingMask = [.maxXMargin, .minYMargin]
        view.addSubview(chooseImageButton)

        removeImageButton.bezelStyle = .rounded
        removeImageButton.target = self
        removeImageButton.action = #selector(removeBackgroundImage)
        removeImageButton.frame = NSRect(x: buttonsX + 148, y: imageRowY + Self.imageRowHeight - 24, width: 90, height: 24)
        removeImageButton.autoresizingMask = [.maxXMargin, .minYMargin]
        view.addSubview(removeImageButton)

        imageStatusLabel.font = .systemFont(ofSize: 11)
        imageStatusLabel.textColor = .secondaryLabelColor
        imageStatusLabel.frame = NSRect(x: buttonsX, y: imageRowY + 2, width: 320, height: 16)
        imageStatusLabel.autoresizingMask = [.maxXMargin, .minYMargin]
        view.addSubview(imageStatusLabel)
    }

    // MARK: - Data

    private func loadSettingsForSelectedProfile() {
        swatchPicker?.removeFromSuperview()
        swatchPicker = nil

        guard let profile = selectedProfile else {
            favoritesCheckbox.isEnabled = false
            frequentlyVisitedCheckbox.isEnabled = false
            chooseImageButton.isEnabled = false
            hasBackgroundImage = false
            updateBackgroundImageControls(forProfileId: nil)
            return
        }
        favoritesCheckbox.isEnabled = true
        frequentlyVisitedCheckbox.isEnabled = true
        chooseImageButton.isEnabled = true

        let settings = StartPageSettingsStore.load(forProfileId: profile.id)
        favoritesCheckbox.state = settings.showFavorites ? .on : .off
        frequentlyVisitedCheckbox.state = settings.showFrequentlyVisited ? .on : .off
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
    }

    private func saveCurrentSettings() {
        guard let profile = selectedProfile else { return }
        let settings = StartPageSettings(
            backgroundColorHex: swatchPicker?.selectedHex ?? ProfileColorPalette.hexValues[7],
            showFavorites: favoritesCheckbox.state == .on,
            showFrequentlyVisited: frequentlyVisitedCheckbox.state == .on,
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
