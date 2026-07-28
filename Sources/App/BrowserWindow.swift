import AppKit
import UniformTypeIdentifiers

/// Custom NSWindow so ⌘1-9 (select tab N) can be handled directly -- unlike
/// the other shortcuts (⌘T, ⌘W, ⌘L, ⌘R, ⌘←/→, ⌘⇧[ / ⌘⇧], ⌘⇧C), digit tab
/// selection isn't exposed as a menu item (nine near-identical menu entries
/// would be clutter, and no mainstream browser does this either), so there is
/// no menu-key-equivalent to intercept it first.
final class BrowserWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command],
           let characters = event.charactersIgnoringModifiers,
           let digit = Int(characters), (1...9).contains(digit),
           let controller = windowController as? BrowserWindowController {
            controller.selectTab(at: digit - 1)
            return true
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
}
