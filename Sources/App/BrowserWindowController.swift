import AppKit

/// One native window: an address field above a browser surface. Deliberately
/// minimal for the M0 spike -- no tabs, no navigation buttons.
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    private let profileName: String
    private let addressField = NSTextField()
    private let hostView = NSView()
    private var browser: BRWBrowser?

    private let initialURL: String

    init(profileName: String, initialURL: String) {
        self.profileName = profileName
        self.initialURL = initialURL
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Browser — \(profileName)"
        window.center()
        super.init(window: window)
        window.delegate = self
        setUpViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setUpViews() {
        guard let contentView = window?.contentView else { return }
        let addressBarHeight: CGFloat = 28
        let margin: CGFloat = 8

        addressField.frame = NSRect(
            x: margin,
            y: contentView.bounds.height - addressBarHeight - margin,
            width: contentView.bounds.width - margin * 2,
            height: addressBarHeight
        )
        addressField.autoresizingMask = [.width, .minYMargin]
        addressField.placeholderString = "Enter a URL and press Return"
        addressField.stringValue = initialURL
        addressField.target = self
        addressField.action = #selector(addressFieldSubmitted)
        contentView.addSubview(addressField)

        hostView.frame = NSRect(
            x: 0,
            y: 0,
            width: contentView.bounds.width,
            height: contentView.bounds.height - addressBarHeight - margin * 2
        )
        hostView.autoresizingMask = [.width, .height]
        hostView.wantsLayer = true
        contentView.addSubview(hostView)
    }

    /// Creates the CEF browser. Must be called only once the window is on
    /// screen so `hostView` has a real frame for CEF's SetAsChild to use.
    func showAndLoadInitialURL() {
        window?.makeKeyAndOrderFront(nil)
        browser = BRWBrowser(
            profileName: profileName,
            hostView: hostView,
            initialURL: addressField.stringValue
        )
    }

    @objc private func addressFieldSubmitted() {
        var text = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !text.contains("://") {
            text = "https://" + text
        }
        addressField.stringValue = text
        browser?.loadURL(text)
    }

    func windowWillClose(_ notification: Notification) {
        browser?.close()
        browser = nil
    }
}
