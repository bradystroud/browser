import AppKit
import UniformTypeIdentifiers

/// Custom NSWindow so ⌘1-9 (select tab N) can be handled directly -- unlike
/// the other shortcuts (⌘T, ⌘W, ⌘L, ⌘R, ⌘←/→, ⌘⇧[ / ⌘⇧], ⌘⇧C), digit tab
/// selection isn't exposed as a menu item (nine near-identical menu entries
/// would be clutter, and no mainstream browser does this either), so there is
/// no menu-key-equivalent to intercept it first.
final class BrowserWindow: NSWindow {
    /// One find bar per window, created lazily the first time ⌘F fires (see
    /// -toggleFindBar:). FindBarController.swift for why this lives here
    /// rather than on BrowserWindowController.
    private let findBar = FindBarController()

    /// One Reader mode controller per window -- see ReaderModeController's
    /// own doc comment for why it lives here too, and attach(to:) for why it
    /// needs to be told about this window explicitly (it isn't created lazily
    /// the way findBar is: it has to be observing tab lifecycle events from
    /// this window's first tab onward, not only once the user first acts).
    private let readerMode = ReaderModeController()

    /// The toolbar downloads button + popover, one per window, attached here
    /// for the same reason readerMode is: it has to be observing download
    /// notifications from this window's first tab onward.
    private let downloadsToolbar = DownloadsToolbarController()

    /// Called by BrowserWindowController.applyChromeLayout whenever the web
    /// content area's top edge may have moved (tab strip shown/hidden,
    /// sidebar toggled), so overlays pinned to that edge follow it.
    func chromeLayoutDidChange() {
        findBar.followContentAreaTop()
    }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        DevBuildIndicator.attach(to: self)
        readerMode.attach(to: self)
        downloadsToolbar.attach(to: self)
        // Idempotent -- see PasswordManagerCoordinator.activate()'s own doc
        // comment for why it's kicked off here rather than in AppDelegate or
        // BrowserWindowController (browser-ojh.1).
        PasswordManagerCoordinator.shared.activate()
        // Same reasoning, for card/address autofill (browser-ojh.2).
        PaymentAddressAutofillCoordinator.shared.activate()
        EmailAutofillCoordinator.shared.activate()
        // Same reasoning, for the per-tab audio indicator (browser-rhi.4).
        TabAudioCoordinator.shared.activate()
        // Same reasoning, for the start page gear button (browser-ymx).
        StartPageSettingsCoordinator.shared.activate()
        // Same reasoning, for reading-list article capture (browser-56p).
        ReadingListCoordinator.shared.activate()
        ElementHiderCoordinator.shared.activate()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The modifier flags that count when matching the chords handled below.
    /// Caps Lock is excluded from the comparison because AppKit's own menu
    /// key-equivalent matching ignores it: without this, leaving Caps Lock on
    /// silently kills every shortcut in performKeyEquivalent(with:) while the
    /// menu-driven ones keep working. Shift is deliberately *not* excluded --
    /// a shifted chord must fall through to the menu item that owns it, which
    /// is what keeps ⌘= (here) and ⌘⇧= (View > Zoom In) from both firing.
    private static let consideredModifiers: NSEvent.ModifierFlags =
        NSEvent.ModifierFlags.deviceIndependentFlagsMask.subtracting(.capsLock)

    /// Whether keyboard focus is inside the active tab's docked developer
    /// tools, on either engine.
    var isDevToolsFocused: Bool {
        guard let view = firstResponder as? NSView,
              let tab = (windowController as? BrowserWindowController)?.activeTab else { return false }
        return tab.devTools.toolsPaneContains(view)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⇧⌘M, Developer > Toggle Device Toolbar, taken before any web view
        // -- the tools' own front-end included -- can claim it.
        if event.modifierFlags.intersection(Self.consideredModifiers) == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "m",
           ActiveEngine.capabilities.responsiveDesignMode,
           let tab = (windowController as? BrowserWindowController)?.activeTab {
            tab.deviceToolbar.toggle()
            return true
        }
        if isDevToolsFocused {
            return performDevToolsKeyEquivalent(with: event)
        }
        if event.modifierFlags.intersection(Self.consideredModifiers) == [.command],
           let characters = event.charactersIgnoringModifiers,
           let controller = windowController as? BrowserWindowController {
            if let digit = Int(characters), (1...9).contains(digit) {
                // Position among *visible* tabs (browser-rhi.1: a collapsed tab
                // group's members don't count), not a raw index into `tabs` --
                // matches Ctrl+Tab cycling's same "visible tabs as one sequence"
                // rule (see BrowserWindowController.visibleTabIndices).
                controller.selectVisibleTab(atPosition: digit - 1)
                return true
            }
            // Plain ⌘= -- the unshifted chord almost everyone actually presses
            // for "zoom in", since + is shifted-= on a US layout (browser-5kq.15).
            // It lives here, alongside ⌘1-9, for the same reason those do: the
            // menu can't express it. A menu item's key equivalent is matched
            // against charactersIgnoringModifiers, which applies Shift, so the
            // View menu's visible "Zoom In ⌘+" item only ever matches ⌘⇧= --
            // and a *hidden* second item carrying "=" does not work either.
            //
            // That last point is worth stating plainly because it was tried and
            // shipped broken: a scratch harness calling NSMenu.performKeyEquivalent
            // directly reports hidden items as honoured, but through the real
            // -[NSApplication sendEvent:] path they are skipped, and plain ⌘= did
            // nothing in Brady's build. See `bd show browser-5kq.15` for the measurements.
            //
            // Guarded on an exact [.command] match (above, see
            // consideredModifiers), so ⌘⇧= never reaches here -- it falls
            // through to super and is handled once by the menu item. Exactly
            // one of the two paths handles any given chord, so a single press
            // can never step two rungs.
            if characters == "=" {
                controller.zoomIn(self)
                return true
            }
            // ⌘[ / ⌘] -- Safari's and Chrome's own back/forward chords,
            // alongside the History menu's ⌘←/⌘→ (Brady's ask). Here rather
            // than on those menu items for the same reason ⌘= is: an
            // NSMenuItem carries exactly one key equivalent, and a second
            // hidden item holding the alternate chord is skipped through the
            // real -[NSApplication sendEvent:] path -- the mistake documented
            // just above, which shipped broken once already.
            //
            // The exact [.command] guard above is what keeps these clear of
            // ⌘⇧[ / ⌘⇧] (previous/next tab): those carry Shift, so they never
            // reach here and are handled once, by their own menu items.
            if characters == "[" {
                controller.goBackAction(self)
                return true
            }
            if characters == "]" {
                controller.goForwardAction(self)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Docked developer tools get ⌘[ / ⌘] (previous/next panel), ⌘1-9
    /// (panel N) and ⌘= (zoom the tools) themselves, as in Chrome: the chords
    /// above are skipped, and the tools' own web view, which takes every ⌘
    /// chord before the menu does, sees them first. Chords the tools leave
    /// unhandled come back to the main menu -- except ⌘F and ⌘P, which
    /// printPage(_:) and toggleFindBar(_:) refuse while the tools have focus.
    /// ⌘W is taken here and closes the tab, which is what Chrome does from
    /// docked tools, so it cannot depend on whether the engine's tools happen
    /// to bind it.
    private func performDevToolsKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(Self.consideredModifiers) == [.command],
           event.charactersIgnoringModifiers == "w",
           let controller = windowController as? BrowserWindowController {
            controller.closeTab(self)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// A browser command bound to a chord the developer tools also use
    /// (⌘F search, ⌘P open file) stays out of their way while they have
    /// focus. Choosing the menu item with the mouse still works.
    private var isDevToolsChord: Bool {
        guard isDevToolsFocused else { return false }
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseUp: return false
        default: return true
        }
    }

    /// ⌘P -- print/export live here on the window itself (rather than on
    /// BrowserWindowController, mirroring ⌘1-9 above) so their menu items can
    /// use a nil target and still resolve through the responder chain
    /// (NSWindow sits in that chain ahead of its NSWindowController) without
    /// adding to BrowserWindowController.swift, which m1-shell's session-
    /// restore work and browser-12m.2's permission-prompt wiring both had
    /// concurrent edits in when this was written (see
    /// docs/ai-tasks/print-export-notes.md).
    @objc func printPage(_ sender: Any?) {
        if isDevToolsChord { return }
        (windowController as? BrowserWindowController)?.activeTab?.print()
    }

    /// NSSavePanel defaults to the active tab's page title as the filename
    /// (falling back to "Untitled" if empty/unsanitizable) -- shown as a
    /// sheet on this window; on confirmation, exports via EngineTab.printToPDF
    /// and shows a failure alert if CEF reports `!success` (no success UI --
    /// the Finder-revealed/created file speaks for itself, same as this
    /// app's existing downloads not popping a "done" dialog either).
    @objc func exportAsPDF(_ sender: Any?) {
        guard let tab = (windowController as? BrowserWindowController)?.activeTab else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.sanitizedFilename(from: tab.title) + ".pdf"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true

        panel.beginSheetModal(for: self) { response in
            guard response == .OK, let url = panel.url else { return }
            tab.exportAsPDF(to: url.path) { success, path in
                guard !success else { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Couldn't Export PDF"
                alert.informativeText = "The page could not be saved as a PDF at \(path)."
                alert.runModal()
            }
        }
    }

    /// Strips characters the filesystem/NSSavePanel would reject from a page
    /// title before offering it as a suggested filename -- "/" is the only
    /// one that's actually illegal in an HFS+/APFS filename, but colons get
    /// silently rewritten to "/" by Finder-facing APIs for legacy reasons, so
    /// both are stripped here to avoid a surprising mismatch between the
    /// suggested and actual saved name.
    private static func sanitizedFilename(from title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    /// ⌘F -- lives here for the same reason -printPage:/-exportAsPDF: do
    /// (see those methods' doc comments): BrowserWindowController was hot
    /// with concurrent Tab Groups work when this was written. Shows the find
    /// bar (creating it lazily) and focuses it; if already showing, just
    /// refocuses -- see FindBarController.show(in:).
    @objc func toggleFindBar(_ sender: Any?) {
        if isDevToolsChord { return }
        findBar.show(in: self)
    }

    /// ⇧⌘R -- Reader mode toggle, same responder-chain placement reasoning
    /// as -toggleFindBar:/-printPage: above (browser-5kq.1).
    @objc func toggleReaderMode(_ sender: Any?) {
        readerMode.toggle()
    }

    @objc func setReaderFontSizeSmall(_ sender: Any?) { readerMode.setFontSize(.small) }
    @objc func setReaderFontSizeMedium(_ sender: Any?) { readerMode.setFontSize(.medium) }
    @objc func setReaderFontSizeLarge(_ sender: Any?) { readerMode.setFontSize(.large) }
}
