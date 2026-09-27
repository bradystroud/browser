import AppKit
import WebKit

/// Printing, for both ⌘P and a page's own window.print(): one print sheet per
/// tab at a time, owned by the same WebKitPageSheetGuard as the page's JS
/// dialogs, so a print request that arrives while any page sheet is up is
/// dropped rather than queued behind it.
extension WebKitTab {
    /// NSPrintOperation(view: webView) prints blank pages -- WKWebView draws
    /// in a separate process, so only its own printOperation(with:) has
    /// anything to put on paper. That operation's view also needs a real
    /// frame before it can paginate, and it has to run as a window-modal
    /// sheet: a plain run() comes back blank as well.
    func print() {
        printFrame(nil, completion: {})
    }

    /// The page called window.print(). WebKit has no public WKUIDelegate hook
    /// for it; this is WKUIDelegatePrivate's, and a delegate that lacks it
    /// makes window.print() a silent no-op. `frame` is the _WKFrameHandle of
    /// the frame that asked (an iframe can print just itself).
    ///
    /// WebKit holds the page's script inside window.print() until
    /// `completionHandler` runs, so on a loaded page it is called when the
    /// sheet ends -- which is also when the page's `afterprint` should fire.
    /// A page that prints itself while still loading (invoice pages do, from
    /// an inline script) is different: WebKit does not defer that call, and
    /// the load cannot finish while the script is held, so the page is
    /// released at once and the sheet waits for the load to end instead.
    /// Otherwise it would paginate a half-parsed page.
    @objc(_webView:printFrame:pdfFirstPageSize:completionHandler:)
    func webView(_ webView: WKWebView, printFrame frame: AnyObject?, pdfFirstPageSize: CGSize, completionHandler: @escaping () -> Void) {
        NSLog("Browser: page requested print%@", webView.isLoading ? " (shown once the page has loaded)" : "")
        guard webView.isLoading else {
            printFrame(frame, completion: completionHandler)
            return
        }
        completionHandler()
        guard deferredPrint == nil else { return }
        deferredPrint = WebKitDeferredPrint(webView: webView) { [weak self] stillOnPage in
            guard let self else { return }
            self.deferredPrint = nil
            if stillOnPage { self.printFrame(frame, completion: {}) }
        }
    }

    /// Prints `frame` (a _WKFrameHandle), or the main frame when nil, and
    /// calls `completion` exactly once: when the sheet ends, when the tab
    /// closes under it, or straight away when no sheet can be shown -- a
    /// background tab, or a print or dialog sheet already up on this tab or
    /// window.
    func printFrame(_ frame: AnyObject?, completion: @escaping () -> Void) {
        let sheetGuard = WebKitPageSheetGuard.guardFor(webView)
        guard let window = webView.window, !sheetGuard.isPresenting, window.attachedSheet == nil else {
            NSLog("Browser: print request ignored -- tab not in a window, or a sheet is already up")
            completion()
            return
        }
        let operation = makePrintOperation(frame: frame)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.view?.frame = webView.bounds
        let runSheet = runPrintSheet
        sheetGuard.present(sheet: nil, on: window, start: { done in
            runSheet(operation, window) { done(.OK) }
        }, finish: { _ in completion() })
    }

    private func makePrintOperation(frame: AnyObject?) -> NSPrintOperation {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        // Half-inch margins all round, close to Safari's own defaults.
        info.topMargin = 36
        info.bottomMargin = 36
        info.leftMargin = 36
        info.rightMargin = 36

        // A subframe's own print() prints just that frame, as in Safari. The
        // SPI is looked up at runtime; without it, or when the frame has
        // already gone (it returns nil), the whole page prints instead.
        let forFrame = NSSelectorFromString("_printOperationWithPrintInfo:forFrame:")
        if let frame, webView.responds(to: forFrame),
           let operation = webView.perform(forFrame, with: info, with: frame)?.takeUnretainedValue() as? NSPrintOperation {
            return operation
        }
        return webView.printOperation(with: info)
    }

    /// The real runPrintSheet.
    static func runPrintOperationSheet(_ operation: NSPrintOperation, on window: NSWindow, didEnd: @escaping () -> Void) {
        let target = PrintSheetCompletion(didEnd)
        operation.runModal(for: window, delegate: target,
                           didRun: #selector(PrintSheetCompletion.printOperationDidRun(_:success:contextInfo:)),
                           contextInfo: Unmanaged.passRetained(target).toOpaque())
    }
}

/// Waits for the web view's current load to end, then calls `loaded` once,
/// saying whether the tab is still on the page that asked. A load that never
/// settles (a hung subresource) is treated as ended after `maximumWait`.
/// Dropping the object cancels it.
final class WebKitDeferredPrint {
    static let maximumWait: TimeInterval = 10

    private weak var webView: WKWebView?
    private let url: URL?
    private var loaded: ((_ stillOnPage: Bool) -> Void)?
    private var observation: NSKeyValueObservation?
    private var timer: Timer?

    init(webView: WKWebView, loaded: @escaping (_ stillOnPage: Bool) -> Void) {
        self.webView = webView
        url = webView.url
        self.loaded = loaded
        observation = webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
            guard !webView.isLoading else { return }
            // KVO arrives mid-update; let WebKit finish reporting the load
            // before a sheet goes up over it.
            DispatchQueue.main.async { self?.fire() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.maximumWait, repeats: false) { [weak self] _ in
            self?.fire()
        }
    }

    private func fire() {
        guard let loaded else { return }
        self.loaded = nil
        observation?.invalidate()
        timer?.invalidate()
        loaded(webView != nil && webView?.url == url)
    }

    deinit {
        observation?.invalidate()
        timer?.invalidate()
    }
}

/// NSPrintOperation's sheet reports back through a target/selector pair; this
/// is that target. It keeps itself alive through `contextInfo` until then.
private final class PrintSheetCompletion: NSObject {
    private let didEnd: () -> Void

    init(_ didEnd: @escaping () -> Void) {
        self.didEnd = didEnd
    }

    @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if let contextInfo {
            Unmanaged<PrintSheetCompletion>.fromOpaque(contextInfo).release()
        }
        didEnd()
    }
}
