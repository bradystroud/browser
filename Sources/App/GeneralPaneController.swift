import AppKit

/// The "General" pane of the Settings window (see SettingsWindowController,
/// which hosts this alongside the other panes in an NSTabView): what new
/// windows open with plus the homepage (browser-m0x), the omnibox
/// display-mode preference (browser-0y1), the search engine and its two
/// opt-in features (browser-0du) and the rendering-engine choice
/// (browser-2a7). All global rather than per-profile -- see
/// HomepagePreference, OmniboxDisplayPreference, SearchEnginePreference and
/// EnginePreference for each one's own reason -- so unlike the other panes
/// there's no profile picker here.
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
        margin + headerHeight
            // New-windows row, homepage row, and their shared help text.
            + rowGap + labelHeight + 6 + rowHeight
            + rowGap + labelHeight + 6 + rowHeight
            + rowGap + homepageHelpHeight
            + rowGap + labelHeight + 6 + rowHeight + rowGap + helpHeight
            // Search engine row, its help, and the two search toggles.
            + rowGap + labelHeight + 6 + rowHeight + rowGap + searchHelpHeight
            + rowGap + checkboxHeight + 6 + suggestionsHelpHeight
            + rowGap + checkboxHeight + 6 + quickSiteHelpHeight
            + rowGap + labelHeight + 6 + rowHeight + rowGap + engineHelpHeight + margin
    var preferredContentHeight: CGFloat { Self.preferredContentHeight }
    /// Taller than the omnibox row's help text: this one has to carry both
    /// the restart requirement and what WebKit can't do.
    private static let engineHelpHeight: CGFloat = 76
    /// Carries either the explanation of the current choice or the
    /// "that isn't a URL" warning, whichever applies -- sized for the longer.
    private static let homepageHelpHeight: CGFloat = 48
    /// Leaves room for "Set to Current Page" beside it on one row.
    private static let homepageFieldWidth: CGFloat = 330
    private static let checkboxHeight: CGFloat = 20
    /// Carries either the name of the selected engine or the "that template
    /// is unusable" warning, whichever applies.
    private static let searchHelpHeight: CGFloat = 34
    /// The longest help text in the pane, and deliberately so: it is the one
    /// that says what leaves the machine.
    private static let suggestionsHelpHeight: CGFloat = 62
    private static let quickSiteHelpHeight: CGFloat = 34
    /// Sits beside the engine popup, on the same row.
    private static let customTemplateFieldWidth: CGFloat = 316

    let view = NSView(frame: NSRect(x: 0, y: 0, width: 536, height: GeneralPaneController.preferredContentHeight))

    /// New windows / homepage (browser-m0x).
    private let newWindowPopup = NSPopUpButton()
    private let homepageField = NSTextField()
    private let setToCurrentPageButton = NSButton()
    private let homepageHelpLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }()

    private let modePopup = NSPopUpButton()
    private let helpLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }()

    /// Search engine, suggestions and Quick Website Search (browser-0du).
    private let searchEnginePopup = NSPopUpButton()
    private let customTemplateField = NSTextField()
    private let searchHelpLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }()
    private let suggestionsCheckbox = NSButton()
    private let suggestionsHelpLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }()
    private let quickSiteCheckbox = NSButton()
    private let quickSiteHelpLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }()
    private static let searchEngineOrder: [SearchEngineChoice] = [.google, .duckDuckGo, .bing, .kagi, .custom]

    /// Engine choice (browser-2a7). Restart-only by nature -- see
    /// EnginePreference's own doc comment.
    private let enginePopup = NSPopUpButton()
    private let engineHelpLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }()
    private static let engineOrder: [EngineChoice] = [.cef, .webkit]

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
        updateSearchRow()

        let engine = EnginePreference.current
        if let index = Self.engineOrder.firstIndex(of: engine) {
            enginePopup.selectItem(at: index)
        }
        updateEngineHelpText(for: engine)
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

        // New windows / homepage (browser-m0x), first because it's the one
        // setting here that changes what ⌘N does.
        let newWindowLabelY = headerLabel.frame.minY - rowGap - labelHeight
        let newWindowLabel = NSTextField(labelWithString: "New windows open with:")
        newWindowLabel.frame = NSRect(
            x: margin, y: newWindowLabelY, width: view.bounds.width - margin * 2, height: labelHeight
        )
        newWindowLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(newWindowLabel)

        let newWindowPopupY = newWindowLabelY - 6 - rowHeight
        newWindowPopup.frame = NSRect(x: margin, y: newWindowPopupY, width: 200, height: rowHeight)
        newWindowPopup.autoresizingMask = [.maxXMargin, .minYMargin]
        for content in NewWindowContent.allCases {
            newWindowPopup.menu?.addItem(NSMenuItem(title: content.title, action: nil, keyEquivalent: ""))
        }
        newWindowPopup.target = self
        newWindowPopup.action = #selector(newWindowContentChanged)
        view.addSubview(newWindowPopup)

        let homepageLabelY = newWindowPopupY - rowGap - labelHeight
        let homepageLabel = NSTextField(labelWithString: "Homepage:")
        homepageLabel.frame = NSRect(
            x: margin, y: homepageLabelY, width: view.bounds.width - margin * 2, height: labelHeight
        )
        homepageLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(homepageLabel)

        let homepageFieldY = homepageLabelY - 6 - rowHeight
        homepageField.frame = NSRect(
            x: margin, y: homepageFieldY, width: Self.homepageFieldWidth, height: rowHeight
        )
        homepageField.autoresizingMask = [.maxXMargin, .minYMargin]
        homepageField.placeholderString = "https://example.org"
        homepageField.target = self
        // Commit on Return; the delegate below also commits on focus loss, so
        // a value typed and then clicked away from is never silently dropped.
        homepageField.action = #selector(homepageCommitted)
        homepageField.delegate = self
        view.addSubview(homepageField)

        setToCurrentPageButton.frame = NSRect(
            x: margin + Self.homepageFieldWidth + 8, y: homepageFieldY, width: 162, height: rowHeight
        )
        setToCurrentPageButton.autoresizingMask = [.maxXMargin, .minYMargin]
        setToCurrentPageButton.title = "Set to Current Page"
        setToCurrentPageButton.bezelStyle = .rounded
        setToCurrentPageButton.target = self
        setToCurrentPageButton.action = #selector(setHomepageToCurrentPage)
        view.addSubview(setToCurrentPageButton)

        let homepageHelpY = homepageFieldY - rowGap - Self.homepageHelpHeight
        homepageHelpLabel.frame = NSRect(
            x: margin, y: homepageHelpY, width: view.bounds.width - margin * 2, height: Self.homepageHelpHeight
        )
        homepageHelpLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(homepageHelpLabel)

        let rowLabelY = homepageHelpY - rowGap - labelHeight
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

        // Search row (browser-0du): the engine popup and, beside it, the
        // template field that only a custom engine uses -- one row rather
        // than two, because the pane is already tall.
        let searchLabelY = helpY - rowGap - labelHeight
        let searchLabel = NSTextField(labelWithString: "Search engine:")
        searchLabel.frame = NSRect(x: margin, y: searchLabelY, width: view.bounds.width - margin * 2, height: labelHeight)
        searchLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(searchLabel)

        let searchPopupY = searchLabelY - 6 - rowHeight
        searchEnginePopup.frame = NSRect(x: margin, y: searchPopupY, width: 200, height: rowHeight)
        searchEnginePopup.autoresizingMask = [.maxXMargin, .minYMargin]
        for choice in Self.searchEngineOrder {
            searchEnginePopup.menu?.addItem(NSMenuItem(title: Self.title(for: choice), action: nil, keyEquivalent: ""))
        }
        searchEnginePopup.target = self
        searchEnginePopup.action = #selector(searchEngineChanged)
        view.addSubview(searchEnginePopup)

        customTemplateField.frame = NSRect(
            x: margin + 208, y: searchPopupY, width: Self.customTemplateFieldWidth, height: rowHeight
        )
        customTemplateField.autoresizingMask = [.maxXMargin, .minYMargin]
        customTemplateField.placeholderString = "https://example.com/search?q={searchTerms}"
        customTemplateField.target = self
        customTemplateField.action = #selector(customTemplateCommitted)
        customTemplateField.delegate = self
        view.addSubview(customTemplateField)

        let searchHelpY = searchPopupY - rowGap - Self.searchHelpHeight
        searchHelpLabel.frame = NSRect(
            x: margin, y: searchHelpY, width: view.bounds.width - margin * 2, height: Self.searchHelpHeight
        )
        searchHelpLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(searchHelpLabel)

        let suggestionsY = searchHelpY - rowGap - Self.checkboxHeight
        suggestionsCheckbox.frame = NSRect(
            x: margin, y: suggestionsY, width: view.bounds.width - margin * 2, height: Self.checkboxHeight
        )
        suggestionsCheckbox.autoresizingMask = [.width, .minYMargin]
        suggestionsCheckbox.setButtonType(.switch)
        suggestionsCheckbox.title = "Show search suggestions"
        suggestionsCheckbox.target = self
        suggestionsCheckbox.action = #selector(suggestionsToggled)
        view.addSubview(suggestionsCheckbox)

        let suggestionsHelpY = suggestionsY - 6 - Self.suggestionsHelpHeight
        suggestionsHelpLabel.frame = NSRect(
            x: margin + 18, y: suggestionsHelpY,
            width: view.bounds.width - margin * 2 - 18, height: Self.suggestionsHelpHeight
        )
        suggestionsHelpLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(suggestionsHelpLabel)

        let quickSiteY = suggestionsHelpY - rowGap - Self.checkboxHeight
        quickSiteCheckbox.frame = NSRect(
            x: margin, y: quickSiteY, width: view.bounds.width - margin * 2, height: Self.checkboxHeight
        )
        quickSiteCheckbox.autoresizingMask = [.width, .minYMargin]
        quickSiteCheckbox.setButtonType(.switch)
        quickSiteCheckbox.title = "Quick Website Search"
        quickSiteCheckbox.target = self
        quickSiteCheckbox.action = #selector(quickSiteToggled)
        view.addSubview(quickSiteCheckbox)

        let quickSiteHelpY = quickSiteY - 6 - Self.quickSiteHelpHeight
        quickSiteHelpLabel.frame = NSRect(
            x: margin + 18, y: quickSiteHelpY,
            width: view.bounds.width - margin * 2 - 18, height: Self.quickSiteHelpHeight
        )
        quickSiteHelpLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(quickSiteHelpLabel)

        // Engine row, same top-down shape as the omnibox row above it.
        let engineLabelY = quickSiteHelpY - rowGap - labelHeight
        let engineLabel = NSTextField(labelWithString: "Rendering engine:")
        engineLabel.frame = NSRect(x: margin, y: engineLabelY, width: view.bounds.width - margin * 2, height: labelHeight)
        engineLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(engineLabel)

        let enginePopupY = engineLabelY - 6 - rowHeight
        enginePopup.frame = NSRect(x: margin, y: enginePopupY, width: 200, height: rowHeight)
        enginePopup.autoresizingMask = [.maxXMargin, .minYMargin]
        for engine in Self.engineOrder {
            enginePopup.menu?.addItem(NSMenuItem(title: Self.title(for: engine), action: nil, keyEquivalent: ""))
        }
        enginePopup.target = self
        enginePopup.action = #selector(engineChanged)
        view.addSubview(enginePopup)

        let engineHelpY = enginePopupY - rowGap - Self.engineHelpHeight
        engineHelpLabel.frame = NSRect(
            x: margin, y: engineHelpY, width: view.bounds.width - margin * 2, height: Self.engineHelpHeight
        )
        engineHelpLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(engineHelpLabel)
    }

    private static func title(for engine: EngineChoice) -> String {
        switch engine {
        case .cef: return "Chromium"
        case .webkit: return "WebKit (experimental)"
        }
    }

    /// Says plainly that the change is restart-only, and -- for WebKit --
    /// what stops working. Both matter: the engine is chosen on the first
    /// line of main.swift (see EnginePreference), and a WebKit session
    /// silently loses a real list of features, including passkeys entirely.
    private func updateEngineHelpText(for engine: EngineChoice) {
        let restartNote = "Takes effect the next time you open Browser. Your windows and tabs are reopened on restart."
        switch engine {
        case .cef:
            engineHelpLabel.stringValue = "Chromium, via CEF \u{2014} the full-featured engine, and the one this browser is built around. \(restartNote)"
        case .webkit:
            engineHelpLabel.stringValue = "WebKit is experimental. Passkeys and security keys don\u{2019}t work at all, and neither do per-tab mute, DevTools, Inspect Element, View Page Source or Responsive Design Mode. Sites are logged out separately from Chromium, since the two engines don\u{2019}t share cookies or storage. \(restartNote)"
        }
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
        customTemplateField.isHidden = !isCustom

        let typed = customTemplateField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let isUnusable = isCustom && !SearchEngine.isValidTemplate(typed)
        let engine = SearchEnginePreference.current

        if isUnusable {
            searchHelpLabel.textColor = .systemRed
            searchHelpLabel.stringValue = typed.isEmpty
                ? "Enter the site\u{2019}s search address with \u{201c}{searchTerms}\u{201d} where your search goes. Until then, searches use \(SearchEngine.default.name)."
                : "\u{201c}\(typed)\u{201d} can\u{2019}t be used: it needs to be an http or https address containing \u{201c}{searchTerms}\u{201d}. Searches use \(SearchEngine.default.name) until it is."
        } else {
            searchHelpLabel.textColor = .secondaryLabelColor
            searchHelpLabel.stringValue = "Anything you type in the address bar that isn\u{2019}t a web address is searched with \(engine.name)."
        }

        // An engine with no suggestion endpoint (a custom one, in practice)
        // can't offer suggestions at all, so the toggle says so rather than
        // appearing to work and doing nothing.
        let canSuggest = engine.suggestURL(for: "test") != nil
        suggestionsCheckbox.isEnabled = canSuggest
        if canSuggest {
            suggestionsHelpLabel.stringValue = "Off by default. When on, what you type in the address bar is sent to \(engine.name) as you type it, so it can suggest completions. Nothing is sent from a Private window, and nothing is sent when this is off. Suggestion requests carry no cookies, so they aren\u{2019}t tied to any account you\u{2019}re signed in to."
        } else {
            suggestionsHelpLabel.stringValue = "A custom search engine can\u{2019}t offer suggestions \u{2014} there\u{2019}s no way to find its suggestion address. Choose a built-in engine to use this."
        }

        quickSiteHelpLabel.stringValue = "Search a site a couple of times and its name becomes a keyword: type \u{201c}wikipedia swift\u{201d} to search Wikipedia directly. Keywords come from your history and never leave your Mac."
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
    /// and the help text either explains the selection or warns that the
    /// typed homepage can't be used.
    private func updateHomepageRow() {
        let content = HomepagePreference.newWindowContent
        let isHomepage = content == .homepage
        homepageField.isEnabled = isHomepage
        setToCurrentPageButton.isEnabled = isHomepage

        let typed = homepageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let isUnusable = isHomepage && !typed.isEmpty && HomepagePreference.normalized(typed) == nil

        if isUnusable {
            homepageHelpLabel.textColor = .systemRed
            homepageHelpLabel.stringValue = "\u{201c}\(typed)\u{201d} isn\u{2019}t a web address, so new windows will open the Start Page instead. Enter a full URL, or a domain like \u{201c}example.org\u{201d}. \u{201c}javascript:\u{201d} and \u{201c}data:\u{201d} addresses aren\u{2019}t allowed here."
            return
        }

        homepageHelpLabel.textColor = .secondaryLabelColor
        switch content {
        case .startPage:
            homepageHelpLabel.stringValue = "\u{2318}N opens the Start Page, with your Favourites and Frequently Visited sites. Customise it in the Start Page settings."
        case .homepage:
            homepageHelpLabel.stringValue = typed.isEmpty
                ? "Enter the address you want \u{2318}N to open. While this is empty, new windows open the Start Page instead."
                : "\u{2318}N opens this address. Private windows always open the Start Page, whatever this is set to."
        case .emptyPage:
            homepageHelpLabel.stringValue = "\u{2318}N opens a blank page with the address bar ready for typing."
        }
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
