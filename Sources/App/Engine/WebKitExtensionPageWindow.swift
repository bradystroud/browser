import AppKit
import WebKit

/// A small window showing one of an extension's own pages, for an extension
/// frame inside a web page that calls `window.open` on its own page with
/// popup features (iCloud Passwords' way to ask for pairing when
/// `action.openPopup()` fails).
///
/// WebKit's own popup cannot be used: the web view `createWebViewWith`
/// returns must be built from the opener's configuration, a web page's, and
/// an extension page only renders in a view built from its context's
/// `webViewConfiguration` -- any other view shows a blank page. So the page
/// opens here, without a `window.opener`, and the page's `window.open`
/// returns null. It may still close itself: WebKit lets a page with a single
/// history entry call `window.close()`.
@available(macOS 15.4, *)
@MainActor
final class WebKitExtensionPageWindow: NSObject, WKUIDelegate, NSWindowDelegate {
    private(set) static var open: [WebKitExtensionPageWindow] = []

    let panel: NSPanel
    let webView: WKWebView

    private init(url: URL, configuration: WKWebViewConfiguration, size: CGSize, title: String) {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable, .utilityWindow],
                        backing: .buffered, defer: false)
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        super.init()
        webView.uiDelegate = self
        webView.autoresizingMask = [.width, .height]
        panel.contentView = webView
        panel.delegate = self
        webView.load(URLRequest(url: url))
    }

    /// Chrome's limits for a popup window's content, so a page cannot ask
    /// for one larger than the screen or too small to read.
    static func size(for features: WKWindowFeatures) -> CGSize {
        let width = features.width.map { CGFloat(truncating: $0) } ?? 400
        let height = features.height.map { CGFloat(truncating: $0) } ?? 300
        return CGSize(width: min(max(width, 100), 800), height: min(max(height, 100), 600))
    }

    /// Opens `url` over `parent`, or does nothing and returns nil when that
    /// would be unsafe. Never while a text field in the key window is being
    /// edited: ordering a window on screen then can take the whole app down
    /// (see AGENTS.md on the omnibox).
    @discardableResult
    static func show(_ url: URL, configuration: WKWebViewConfiguration, features: WKWindowFeatures,
                     title: String, over parent: NSWindow?) -> WebKitExtensionPageWindow? {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor {
            NSLog("Browser: not opening an extension page window while a text field is being edited")
            return nil
        }
        let window = WebKitExtensionPageWindow(url: url, configuration: configuration, size: size(for: features), title: title)
        if let parent {
            let frame = parent.frame
            window.panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - window.panel.frame.width / 2, y: frame.maxY - 60))
        } else {
            window.panel.center()
        }
        open.append(window)
        window.panel.makeKeyAndOrderFront(nil)
        return window
    }

    func webViewDidClose(_ webView: WKWebView) {
        panel.close()
    }

    func windowWillClose(_ notification: Notification) {
        webView.uiDelegate = nil
        Self.open.removeAll { $0 === self }
    }
}
