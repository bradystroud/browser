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

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        readerMode.attach(to: self)
        downloadsToolbar.attach(to: self)
        // Idempotent -- see PasswordManagerCoordinator.activate()'s own doc
        // comment for why it's kicked off here rather than in AppDelegate or
        // BrowserWindowController (browser-ojh.1).
        PasswordManagerCoordinator.shared.activate()
        // Same reasoning, for card/address autofill (browser-ojh.2).
        PaymentAddressAutofillCoordinator.shared.activate()
        // Same reasoning, for the per-tab audio indicator (browser-rhi.4).
        TabAudioCoordinator.shared.activate()
        // Same reasoning, for the start page gear button (browser-ymx).
        StartPageSettingsCoordinator.shared.activate()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command],
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
            // nothing in Brady's build. See docs/ai-tasks/page-zoom-notes.md.
            //
            // Guarded on an exact [.command] match (above), so ⌘⇧= never reaches
            // here -- it falls through to super and is handled once by the menu
            // item. Exactly one of the two paths handles any given chord, so a
            // single press can never step two rungs.
            if characters == "=" {
                controller.zoomIn(self)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
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
