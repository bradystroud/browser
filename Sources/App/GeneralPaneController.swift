import AppKit

/// The "General" pane of the Settings window (see SettingsWindowController,
/// which hosts this alongside the other panes): what new
/// windows open with plus the homepage (browser-m0x), the omnibox
/// display-mode preference (browser-0y1), the search engine and its two
/// opt-in features (browser-0du), tab sleep, and the rendering-engine choice
/// (browser-2a7). All global rather than per-profile -- see
/// HomepagePreference, OmniboxDisplayPreference, SearchEnginePreference,
/// TabSleepPreferences and EnginePreference for each one's own reason -- so unlike the other panes
/// there's no profile picker here.
final class GeneralPaneController: NSObject, SettingsPaneController {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 400))
    private let form = SettingsForm()

    /// New windows / homepage (browser-m0x).
    private let newWindowPopup = NSPopUpButton()
    private let homepageField = NSTextField()
    private let setToCurrentPageButton = NSButton()
    /// Shown only while Homepage is the choice: the other choices say
    /// everything in their own titles.
    private let homepageHelpLabel = SettingsForm.footnote()
    private var homepageHelpRow: NSGridRow?

    private let modePopup = NSPopUpButton()
    private let helpLabel = SettingsForm.footnote()

    /// Search engine, suggestions and Quick Website Search (browser-0du).
    private let searchEnginePopup = NSPopUpButton()
    private let customTemplateField = NSTextField()
    private var customTemplateRow: NSGridRow?
    /// Only shown while a custom template can't be used -- the engine popup
    /// already says which engine searches go to.
    private let searchHelpLabel = SettingsForm.footnote()
    private var searchHelpRow: NSGridRow?
    private let suggestionsCheckbox = NSButton()
    private let suggestionsHelpLabel = SettingsForm.footnote()
    private let quickSiteCheckbox = NSButton()
    private let quickSiteHelpLabel = SettingsForm.footnote()
    private let autoScrollCheckbox = NSButton()
    private let autoScrollHelpLabel = SettingsForm.footnote(
        "Middle-click an empty part of a page, then move the pointer to scroll. Click again or press Escape to stop.")
    private let linkPeekCheckbox = NSButton()
    private let linkPeekHelpLabel = SettingsForm.footnote(
        "Opens the link in a panel over the page, which you can keep as a tab. Without this, ⌥⇧-click opens a new window like ⇧-click.")
    private static let searchEngineOrder: [SearchEngineChoice] = [.google, .duckDuckGo, .bing, .kagi, .custom]

    /// Engine choice (browser-2a7). Restart-only by nature -- see
    /// EnginePreference's own doc comment.
    private let enginePopup = NSPopUpButton()
    private let engineHelpLabel = SettingsForm.footnote()
    private static let engineOrder: [EngineChoice] = [.cef, .webkit]

    private let backgroundTabsSlider: NSSlider = {
        let slider = NSSlider(value: 1, minValue: 0, maxValue: Double(BackgroundTabPolicy.allCases.count - 1), target: nil, action: nil)
        slider.numberOfTickMarks = BackgroundTabPolicy.allCases.count
        slider.allowsTickMarkValuesOnly = true
        return slider
    }()
    private let backgroundTabsMinLabel = GeneralPaneController.sliderEndLabel("Save memory", alignment: .left)
    private let backgroundTabsMidLabel = GeneralPaneController.sliderEndLabel("Balanced", alignment: .center)
    private let backgroundTabsMaxLabel = GeneralPaneController.sliderEndLabel("Keep tabs ready", alignment: .right)
    private let backgroundTabsHelpLabel = SettingsForm.footnote()
    /// Tab sleep (see TabSleepCoordinator).
    private let tabSleepCheckbox = NSButton()
    private let tabSleepAfterLabel = NSTextField(labelWithString: "after")
    private let tabSleepAfterPopup = NSPopUpButton()
    private let tabSleepHelpLabel = SettingsForm.footnote()
    private static let tabSleepIntervals: [(title: String, seconds: TimeInterval)] = [
        ("5 minutes", 5 * 60), ("15 minutes", 15 * 60), ("30 minutes", 30 * 60),
        ("1 hour", 60 * 60), ("2 hours", 2 * 60 * 60),
    ]

    override init() {
        super.init()
        setUpViews()
        reload()
    }

    func reload() {
        let content = HomepagePreference.newWindowContent
        if let index = NewWindowContent.allCases.firstIndex(of: content) {
            newWindowPopup.selectItem(at: index)
        }
        homepageField.stringValue = HomepagePreference.homepage
        updateHomepageRow()

        let current = OmniboxDisplayPreference.current
        if let index = OmniboxDisplayMode.allCases.firstIndex(of: current) {
            modePopup.selectItem(at: index)
        }
        updateHelpText(for: current)

        if let index = Self.searchEngineOrder.firstIndex(of: SearchEnginePreference.choice) {
            searchEnginePopup.selectItem(at: index)
        }
        customTemplateField.stringValue = SearchEnginePreference.customTemplate
        suggestionsCheckbox.state = SearchEnginePreference.suggestionsEnabled ? .on : .off
        quickSiteCheckbox.state = SearchEnginePreference.quickSiteSearchEnabled ? .on : .off
        linkPeekCheckbox.state = LinkPeekPreference.isEnabled ? .on : .off
        updateSearchRow()
        updateTabSleepRow()

        autoScrollCheckbox.state = AutoScrollPreference.isEnabled ? .on : .off

        let engine = EnginePreference.current
        if let index = Self.engineOrder.firstIndex(of: engine) {
            enginePopup.selectItem(at: index)
        }
        updateEngineHelpText(for: engine)

        let policy = BackgroundTabPolicyPreference.current
        backgroundTabsSlider.integerValue = BackgroundTabPolicy.allCases.firstIndex(of: policy) ?? 1
        updateBackgroundTabsRow(for: policy)
    }

    /// Six groups, top to bottom: new windows, the address bar, search,
    /// the mouse, background tabs, and the engine.
    private func setUpViews() {
        // New windows / homepage (browser-m0x), first because it's the one
        // setting here that changes what ⌘N does.
        for content in NewWindowContent.allCases {
            newWindowPopup.menu?.addItem(NSMenuItem(title: content.title, action: nil, keyEquivalent: ""))
        }
        newWindowPopup.target = self
        newWindowPopup.action = #selector(newWindowContentChanged)
        form.addRow("New windows open with:", newWindowPopup)

        homepageField.placeholderString = "https://example.org"
        homepageField.target = self
        // Commit on Return; the delegate below also commits on focus loss, so
        // a value typed and then clicked away from is never silently dropped.
        homepageField.action = #selector(homepageCommitted)
        homepageField.delegate = self
        homepageField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        homepageField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        setToCurrentPageButton.title = "Set to Current Page"
        setToCurrentPageButton.bezelStyle = .rounded
        setToCurrentPageButton.target = self
        setToCurrentPageButton.action = #selector(setHomepageToCurrentPage)
        let homepageRow = form.addRow(SettingsForm.label("Homepage:"), [homepageField, setToCurrentPageButton])
        homepageRow.cell(at: 1).xPlacement = .fill
        homepageHelpRow = form.addFootnote(homepageHelpLabel)

        form.beginSection()
        for mode in OmniboxDisplayMode.allCases {
            modePopup.menu?.addItem(NSMenuItem(title: mode.title, action: nil, keyEquivalent: ""))
        }
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        form.addRow("Address bar shows:", modePopup)
        form.addFootnote(helpLabel)

        // Search (browser-0du): the engine popup, then the template field
        // that only a custom engine uses.
        form.beginSection()
        for choice in Self.searchEngineOrder {
            searchEnginePopup.menu?.addItem(NSMenuItem(title: Self.title(for: choice), action: nil, keyEquivalent: ""))
        }
        searchEnginePopup.target = self
        searchEnginePopup.action = #selector(searchEngineChanged)
        form.addRow("Search engine:", searchEnginePopup)

        customTemplateField.placeholderString = "https://example.com/search?q={searchTerms}"
        customTemplateField.target = self
        customTemplateField.action = #selector(customTemplateCommitted)
        customTemplateField.delegate = self
        customTemplateRow = form.addFillingRow("Search address:", customTemplateField)
        searchHelpRow = form.addFootnote(searchHelpLabel)

        suggestionsCheckbox.setButtonType(.switch)
        suggestionsCheckbox.title = "Show search suggestions"
        suggestionsCheckbox.target = self
        suggestionsCheckbox.action = #selector(suggestionsToggled)
        form.addRow(nil, suggestionsCheckbox)
        form.addFootnote(suggestionsHelpLabel, indented: true)

        quickSiteCheckbox.setButtonType(.switch)
        quickSiteCheckbox.title = "Quick Website Search"
        quickSiteCheckbox.target = self
        quickSiteCheckbox.action = #selector(quickSiteToggled)
        form.addRow(nil, quickSiteCheckbox)
        form.addFootnote(quickSiteHelpLabel, indented: true)

        form.beginSection()
        autoScrollCheckbox.setButtonType(.switch)
        autoScrollCheckbox.title = "Scroll with the middle button"
        autoScrollCheckbox.target = self
        autoScrollCheckbox.action = #selector(autoScrollToggled)
        form.addRow("Mouse:", autoScrollCheckbox)
        form.addFootnote(autoScrollHelpLabel, indented: true)

        linkPeekCheckbox.setButtonType(.switch)
        linkPeekCheckbox.title = "Peek at links with ⌥⇧-click"
        linkPeekCheckbox.target = self
        linkPeekCheckbox.action = #selector(linkPeekToggled)
        form.addRow(nil, linkPeekCheckbox)
        form.addFootnote(linkPeekHelpLabel, indented: true)

        // Tab sleep sits under the background-tab slider as one group: the
        // slider sets how the engine treats a hidden tab, and the sleep row
        // decides when the app unloads one altogether.
        form.beginSection()
        backgroundTabsSlider.target = self
        backgroundTabsSlider.action = #selector(backgroundTabsChanged)
        backgroundTabsSlider.widthAnchor.constraint(equalToConstant: Self.backgroundTabsSliderWidth).isActive = true
        let sliderRow = form.addRow("Background tabs:", backgroundTabsSlider)
        sliderRow.rowAlignment = .none
        sliderRow.yPlacement = .center
        let tickLabelsRow = form.addRow(nil, sliderTickLabels())
        tickLabelsRow.topPadding = SettingsForm.footnoteGap - SettingsForm.rowSpacing
        tickLabelsRow.rowAlignment = .none
        form.addFootnote(backgroundTabsHelpLabel)

        // The checkbox and its interval read as one sentence:
        // "Put inactive tabs to sleep after [30 minutes]".
        tabSleepCheckbox.setButtonType(.switch)
        tabSleepCheckbox.title = "Put inactive tabs to sleep"
        tabSleepCheckbox.target = self
        tabSleepCheckbox.action = #selector(tabSleepToggled)
        for interval in Self.tabSleepIntervals {
            tabSleepAfterPopup.menu?.addItem(NSMenuItem(title: interval.title, action: nil, keyEquivalent: ""))
        }
        tabSleepAfterPopup.target = self
        tabSleepAfterPopup.action = #selector(tabSleepIntervalChanged)
        let tabSleepRow = form.addRow(nil, [tabSleepCheckbox, tabSleepAfterLabel, tabSleepAfterPopup])
        tabSleepRow.topPadding = SettingsForm.rowSpacing
        (tabSleepRow.cell(at: 1).contentView as? NSStackView)?.spacing = 4
        form.addFootnote(tabSleepHelpLabel, indented: true)

        form.beginSection()
        for engine in Self.engineOrder {
            enginePopup.menu?.addItem(NSMenuItem(title: Self.title(for: engine), action: nil, keyEquivalent: ""))
        }
        enginePopup.target = self
        enginePopup.action = #selector(engineChanged)
        form.addRow("Rendering engine:", enginePopup)
        form.addFootnote(engineHelpLabel)

        form.install(in: view)
    }

    /// "Save memory · Balanced · Keep tabs ready" under the slider's three
    /// stops, spanning exactly the slider's width.
    private func sliderTickLabels() -> NSView {
        let container = NSView()
        let labels = [backgroundTabsMinLabel, backgroundTabsMidLabel, backgroundTabsMaxLabel]
        for label in labels {
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            label.topAnchor.constraint(equalTo: container.topAnchor).isActive = true
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.backgroundTabsSliderWidth),
            backgroundTabsMinLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backgroundTabsMidLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            backgroundTabsMaxLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    // MARK: - Layout

    func preferredContentHeight(forWidth width: CGFloat) -> CGFloat {
        form.fittingHeight
    }

    /// After a help label's text changes: re-flow the pane and let the
    /// hosting scroll view pick up its new height.
    private func helpTextDidChange() {
        invalidateContentHeight()
    }

    private static func title(for engine: EngineChoice) -> String {
        switch engine {
        case .cef: return "Chromium"
        case .webkit: return "WebKit"
        }
    }

    /// Says plainly that the change is restart-only, and -- for WebKit --
    /// what stops working. Both matter: the engine is chosen on the first
    /// line of main.swift (see EnginePreference), and a WebKit session
    /// silently loses a real list of features.
    private func updateEngineHelpText(for engine: EngineChoice) {
        let restartNote = "Takes effect the next time you open Browser. Your windows and tabs are reopened on restart."
        switch engine {
        case .cef:
            engineHelpLabel.stringValue = "Chromium, via CEF. Passkeys work through your phone or a security key, not Touch ID. \(restartNote)"
        case .webkit:
            engineHelpLabel.stringValue = "WebKit, the engine Safari uses. Passkeys work with Touch ID and iCloud Keychain. \(Self.missingFeaturesSentence(for: engine.engine.capabilities))Sites are logged out separately from Chromium, since the two engines don\u{2019}t share cookies or storage. \(restartNote)"
        }
        helpTextDidChange()
    }

    /// "X, Y and Z don't work. " for whatever `capabilities` lacks, or "".
    private static func missingFeaturesSentence(for capabilities: EngineCapabilities) -> String {
        var missing: [String] = []
        if !capabilities.inAppDevTools { missing.append("Built-in developer tools and Inspect Element") }
        if !capabilities.responsiveDesignMode { missing.append("Responsive Design Mode") }
        if !capabilities.perTabAudioMute { missing.append("Per-tab mute") }
        if !capabilities.perTabCPUUsage { missing.append("Per-tab CPU use in Tab Overview") }
        if !capabilities.customContextMenuItems { missing.append("View Page Source, Look Up Image and the other extra right-click items") }
        guard let last = missing.popLast() else { return "" }
        let list = missing.isEmpty ? last : missing.joined(separator: ", ") + " and " + last
        return "\(list) don\u{2019}t work. "
    }

    private static let backgroundTabsSliderWidth: CGFloat = 320

    private static func sliderEndLabel(_ text: String, alignment: NSTextAlignment) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = alignment
        return label
    }

    /// The setting only exists where the running engine can honour it.
    /// Chromium never suspends a hidden tab, so there it is shown disabled
    /// with the reason, rather than hidden.
    private func updateBackgroundTabsRow(for policy: BackgroundTabPolicy) {
        let supported = ActiveEngine.capabilities.backgroundTabPolicy
        backgroundTabsSlider.isEnabled = supported
        guard supported else {
            backgroundTabsHelpLabel.stringValue = "Chromium keeps every open tab loaded, so there is nothing to adjust. This setting applies to the WebKit engine on macOS 14 or later."
            helpTextDidChange()
            return
        }
        switch policy {
        case .saveMemory:
            backgroundTabsHelpLabel.stringValue = "Tabs you aren\u{2019}t looking at stop running. macOS can take back their memory, and then the page reloads when you return to it. Uses the least memory and battery."
        case .balanced:
            backgroundTabsHelpLabel.stringValue = "Tabs you aren\u{2019}t looking at keep running slowly and stay loaded, so they rarely reload when you return. Uses more memory than Save memory."
        case .keepReady:
            backgroundTabsHelpLabel.stringValue = "Tabs you aren\u{2019}t looking at keep running at full speed, so music, timers and live pages never pause. Uses the most memory and battery."
        }
        helpTextDidChange()
    }

    @objc private func backgroundTabsChanged() {
        let cases = BackgroundTabPolicy.allCases
        let policy = cases[min(max(backgroundTabsSlider.integerValue, 0), cases.count - 1)]
        guard policy != BackgroundTabPolicyPreference.current else { return }
        BackgroundTabPolicyPreference.current = policy
        updateBackgroundTabsRow(for: policy)
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
        helpTextDidChange()
    }

    @objc private func engineChanged() {
        let index = enginePopup.indexOfSelectedItem
        guard Self.engineOrder.indices.contains(index) else { return }
        let engine = Self.engineOrder[index]
        EnginePreference.current = engine
        updateEngineHelpText(for: engine)
    }

    @objc private func modeChanged() {
        let index = modePopup.indexOfSelectedItem
        guard OmniboxDisplayMode.allCases.indices.contains(index) else { return }
        let mode = OmniboxDisplayMode.allCases[index]
        OmniboxDisplayPreference.current = mode
        updateHelpText(for: mode)
    }

    // MARK: - Search (browser-0du)

    private static func title(for choice: SearchEngineChoice) -> String {
        SearchEngine.builtIn(choice)?.name ?? "Custom\u{2026}"
    }

    @objc private func searchEngineChanged() {
        let index = searchEnginePopup.indexOfSelectedItem
        guard Self.searchEngineOrder.indices.contains(index) else { return }
        SearchEnginePreference.choice = Self.searchEngineOrder[index]
        updateSearchRow()
    }

    /// Commits the custom template, rewriting the field to the trimmed form
    /// that was actually stored. An unusable template is stored as typed
    /// rather than discarded -- a half-finished URL shouldn't vanish on
    /// focus loss -- and `SearchEnginePreference.current` falls back to the
    /// default engine for exactly that state, so searching still works.
    @objc private func customTemplateCommitted() {
        SearchEnginePreference.customTemplate =
            customTemplateField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        customTemplateField.stringValue = SearchEnginePreference.customTemplate
        updateSearchRow()
    }

    @objc private func suggestionsToggled() {
        SearchEnginePreference.suggestionsEnabled = suggestionsCheckbox.state == .on
        updateSearchRow()
    }

    @objc private func autoScrollToggled() {
        AutoScrollPreference.isEnabled = autoScrollCheckbox.state == .on
    }

    @objc private func linkPeekToggled() {
        LinkPeekPreference.isEnabled = linkPeekCheckbox.state == .on
    }

    @objc private func quickSiteToggled() {
        SearchEnginePreference.quickSiteSearchEnabled = quickSiteCheckbox.state == .on
        updateSearchRow()
    }

    /// Keeps the whole search block consistent with the current choice: the
    /// template field only matters for a custom engine, suggestions are only
    /// offered by an engine that has an endpoint for them, and the help text
    /// either explains the selection or warns that the template is unusable.
    private func updateSearchRow() {
        let choice = SearchEnginePreference.choice
        let isCustom = choice == .custom
        // Hidden rather than merely disabled: a greyed-out field carrying a
        // placeholder still reads as something to fill in, and there is
        // nothing to fill in until Custom is the selection.
        customTemplateRow?.isHidden = !isCustom

        let typed = customTemplateField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let isUnusable = isCustom && !SearchEngine.isValidTemplate(typed)
        let engine = SearchEnginePreference.current
        searchHelpRow?.isHidden = !isUnusable

        if isUnusable {
            searchHelpLabel.textColor = .systemRed
            searchHelpLabel.stringValue = typed.isEmpty
                ? "Enter the site\u{2019}s search address with \u{201c}{searchTerms}\u{201d} where your search goes. Until then, searches use \(SearchEngine.default.name)."
                : "\u{201c}\(typed)\u{201d} can\u{2019}t be used: it needs to be an http or https address containing \u{201c}{searchTerms}\u{201d}. Searches use \(SearchEngine.default.name) until it is."
        }

        // An engine with no suggestion endpoint (a custom one, in practice)
        // can't offer suggestions at all, so the toggle says so rather than
        // appearing to work and doing nothing.
        let canSuggest = engine.suggestURL(for: "test") != nil
        suggestionsCheckbox.isEnabled = canSuggest
        if canSuggest {
            suggestionsHelpLabel.stringValue = "Sends what you type in the address bar to \(engine.name) as you type it. Never from a Private window, and without cookies, so it isn\u{2019}t tied to any account you\u{2019}re signed in to."
        } else {
            suggestionsHelpLabel.stringValue = "A custom search engine can\u{2019}t offer suggestions \u{2014} there\u{2019}s no way to find its suggestion address. Choose a built-in engine to use this."
        }

        quickSiteHelpLabel.stringValue = "Type \u{201c}wikipedia swift\u{201d} to search Wikipedia directly, for any site you have searched before. Keywords come from your history and never leave your Mac."
        helpTextDidChange()
    }

    // MARK: - Tab sleep

    @objc private func tabSleepToggled() {
        TabSleepPreferences.isEnabled = tabSleepCheckbox.state == .on
        updateTabSleepRow()
    }

    @objc private func tabSleepIntervalChanged() {
        let index = tabSleepAfterPopup.indexOfSelectedItem
        guard Self.tabSleepIntervals.indices.contains(index) else { return }
        TabSleepPreferences.idleInterval = Self.tabSleepIntervals[index].seconds
        updateTabSleepRow()
    }

    /// An interval stored outside the menu's choices (set by hand for
    /// testing) selects the nearest one rather than showing nothing.
    private func updateTabSleepRow() {
        let enabled = TabSleepPreferences.isEnabled
        tabSleepCheckbox.state = enabled ? .on : .off
        let stored = TabSleepPreferences.idleInterval
        let nearest = Self.tabSleepIntervals.indices.min {
            abs(Self.tabSleepIntervals[$0].seconds - stored) < abs(Self.tabSleepIntervals[$1].seconds - stored)
        } ?? 2
        tabSleepAfterPopup.selectItem(at: nearest)
        tabSleepAfterPopup.isEnabled = enabled
        tabSleepAfterLabel.textColor = enabled ? .labelColor : .disabledControlTextColor
        tabSleepHelpLabel.stringValue = "A sleeping tab lets go of its page and reloads when you select it. Pinned and private tabs, and tabs playing sound, downloading or holding something you\u{2019}ve typed, stay awake."
        helpTextDidChange()
    }

    // MARK: - New windows / homepage (browser-m0x)

    @objc private func newWindowContentChanged() {
        let index = newWindowPopup.indexOfSelectedItem
        guard NewWindowContent.allCases.indices.contains(index) else { return }
        HomepagePreference.newWindowContent = NewWindowContent.allCases[index]
        updateHomepageRow()
    }

    /// Commits whatever is in the field, rewriting it to the URL the app
    /// actually resolved. That rewrite is the feedback: typing "example.org"
    /// and seeing it become "https://example.org" is how the user learns the
    /// bare-domain rule applied, without a word of explanation.
    @objc private func homepageCommitted() {
        let typed = homepageField.stringValue
        if let normalized = HomepagePreference.normalized(typed) {
            homepageField.stringValue = normalized
            HomepagePreference.homepage = normalized
        } else {
            // Store it as typed rather than discarding it -- a half-finished
            // URL the user is still working on shouldn't vanish on focus
            // loss. `newWindowURL` falls back to the start page for exactly
            // this state, so an unusable value can't navigate anywhere.
            HomepagePreference.homepage = typed
        }
        updateHomepageRow()
    }

    @objc private func setHomepageToCurrentPage() {
        // The frontmost browser window's active tab, not the Settings window
        // itself. An empty urlString means that tab is showing the internal
        // start page (see Tab.urlString), which has no address to capture.
        guard let urlString = WindowManager.shared.keyBrowserWindowController?.activeTab?.urlString,
              !urlString.isEmpty else {
            NSSound.beep()
            return
        }
        homepageField.stringValue = urlString
        homepageCommitted()
    }

    /// Keeps the homepage field, its button and its help text consistent with
    /// the current choice: the field only matters when Homepage is selected,
    /// and the help text, shown only then, either says what the homepage
    /// does or warns that the typed one can't be used.
    private func updateHomepageRow() {
        defer { helpTextDidChange() }
        let content = HomepagePreference.newWindowContent
        let isHomepage = content == .homepage
        homepageField.isEnabled = isHomepage
        setToCurrentPageButton.isEnabled = isHomepage

        let typed = homepageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let isUnusable = isHomepage && !typed.isEmpty && HomepagePreference.normalized(typed) == nil
        homepageHelpRow?.isHidden = !isHomepage

        if isUnusable {
            homepageHelpLabel.textColor = .systemRed
            homepageHelpLabel.stringValue = "\u{201c}\(typed)\u{201d} isn\u{2019}t a web address, so new windows will open the Start Page instead. Enter a full URL, or a domain like \u{201c}example.org\u{201d}. \u{201c}javascript:\u{201d} and \u{201c}data:\u{201d} addresses aren\u{2019}t allowed here."
            return
        }

        homepageHelpLabel.textColor = .secondaryLabelColor
        homepageHelpLabel.stringValue = typed.isEmpty
            ? "Enter the address you want \u{2318}N to open. While this is empty, new windows open the Start Page instead."
            : "Private windows always open the Start Page."
    }
}

extension GeneralPaneController: NSTextFieldDelegate {
    /// Commits on focus loss as well as on Return -- a homepage typed and
    /// then abandoned by clicking elsewhere in Settings is still what the
    /// user meant.
    func controlTextDidEndEditing(_ obj: Notification) {
        let field = obj.object as? NSTextField
        if field === homepageField { homepageCommitted() }
        if field === customTemplateField { customTemplateCommitted() }
    }
}
