import AppKit

/// Owns the one page-initiated sheet (JS alert/confirm/prompt, or a file
/// picker) a WebKitTab may have up at a time, and guarantees WebKit's
/// completion handler for it runs exactly once.
///
/// WebKit asserts, and the page's script stays blocked forever, if a
/// WKUIDelegate completion handler is dropped, so every way a sheet can end
/// has to funnel through `finish`: the user answering it, the tab being
/// switched away from (its host view leaves the window), and the tab closing
/// (`WebKitTab.close()` removes the web view from its superview). The last two
/// both arrive here as `viewWillMove(toWindow:)`, because this view is a
/// zero-size subview of the web view -- which is what lets it observe tab
/// teardown without WebKitTab.close() having to know about sheets at all.
final class WebKitPageSheetGuard: NSView {
    private var parentWindow: NSWindow?
    private var sheet: NSWindow?
    private var finish: ((NSApplication.ModalResponse) -> Void)?

    var isPresenting: Bool { finish != nil }

    /// Finds or installs the guard for `webView`.
    static func guardFor(_ webView: NSView) -> WebKitPageSheetGuard {
        if let existing = webView.subviews.lazy.compactMap({ $0 as? WebKitPageSheetGuard }).first {
            return existing
        }
        let sheetGuard = WebKitPageSheetGuard(frame: .zero)
        sheetGuard.isHidden = true
        webView.addSubview(sheetGuard)
        return sheetGuard
    }

    /// Presents `sheet` on `window` via `start`, which must begin the sheet
    /// and route its own completion into the closure it is given. `finish`
    /// runs exactly once, with `.cancel` when the sheet is torn down rather
    /// than answered.
    func present(sheet: NSWindow, on window: NSWindow,
                 start: (@escaping (NSApplication.ModalResponse) -> Void) -> Void,
                 finish: @escaping (NSApplication.ModalResponse) -> Void) {
        self.parentWindow = window
        self.sheet = sheet
        self.finish = finish
        start { [weak self] response in
            self?.complete(response)
        }
    }

    /// Ends any sheet this guard owns, answering the page with the default.
    func cancel() {
        guard isPresenting else { return }
        if let sheet, let parentWindow, sheet.sheetParent === parentWindow {
            parentWindow.endSheet(sheet, returnCode: .cancel)
        } else {
            // Still queued behind another sheet (or never attached), so
            // endSheet would not reach it -- drop it from the queue by
            // ordering it out, and answer the page directly.
            sheet?.orderOut(nil)
        }
        // endSheet normally calls the sheet's completion synchronously; this
        // covers the cases where it does not, and is a no-op otherwise.
        complete(.cancel)
    }

    private func complete(_ response: NSApplication.ModalResponse) {
        guard let finish else { return }
        self.finish = nil
        sheet = nil
        parentWindow = nil
        finish(response)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow !== window {
            cancel()
        }
    }
}
