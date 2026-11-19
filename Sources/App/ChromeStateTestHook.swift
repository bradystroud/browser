import AppKit

/// `--test-chrome-state <token,token,...>`: puts a scratch instance's first
/// window straight into one chrome layout state and holds it there, so an
/// agent can screenshot the state and read `--chrome-frames-report` without
/// driving the UI. It does nothing without the flag, and nothing without
/// `--profiles-root` either: it writes layout preferences, which must never
/// be the real ones.
///
/// Tokens (the ones left out take the value in brackets):
///
/// - `top` | `sidebar` -- the layout [top]
/// - `in` | `above` -- where the sidebar keeps the address bar [in]
/// - `left` | `right` -- the sidebar's edge [left]
/// - `width=<points>` -- the sidebar's width [the standard one]
/// - `compact`, `hidden`, `always` (always show the tab bar) [off]
/// - `out` -- brings a compact or hidden sidebar out after `delay` and keeps
///   it out
/// - `delay=<seconds>` -- when `out` happens, after the window shows [4]
/// - `slow=<factor>` -- runs every ChromeMotion animation that many times
///   slower, so a screenshot can land in the middle of one [1]
/// - `tabs` -- fills the window: a pinned tab, a group of two, a tab with a
///   long address, and takes the keyboard out of the address bar
/// - `private` -- also opens a private window
enum ChromeStateTestHook {
    private static let tokens: [String] = {
        let args = CommandLine.arguments
        guard args.contains("--profiles-root"),
              let index = args.firstIndex(of: "--test-chrome-state"), index + 1 < args.count else { return [] }
        return args[index + 1].split(separator: ",").map(String.init)
    }()

    static var isRequested: Bool { !tokens.isEmpty }

    private static func has(_ token: String) -> Bool { tokens.contains(token) }

    private static func number(_ key: String) -> Double? {
        tokens.first { $0.hasPrefix("\(key)=") }.flatMap { Double($0.dropFirst(key.count + 1)) }
    }

    /// Whether a compact or hidden sidebar comes out by itself and stays.
    static var bringsSidebarOut: Bool { has("out") }
    static var sidebarOutDelay: TimeInterval { number("delay") ?? 4 }
    /// How many times slower ChromeMotion runs.
    static let timeScale: Double = max(1, number("slow") ?? 1)

    /// Before the first window exists: the layout preferences for the state.
    static func applyPreferences() {
        guard isRequested else { return }
        SidebarLayoutPreference.edge = has("right") ? .right : .left
        TabStripOrientationPreference.addressBar = has("above") ? .abovePage : .inSidebar
        TabStripOrientationPreference.choose(has("sidebar") ? .sidebar : .top)
        if let width = number("width") { VerticalTabsWidthPreference.width = CGFloat(width) }
        CompactTabsPreference.isEnabled = has("compact")
        AlwaysShowTabBarPreference.isEnabled = has("always")
        // Last: choosing a layout shows the sidebar.
        TabsHiddenPreference.isHidden = has("hidden")
    }

    private static var didSetUpWindow = false

    /// When the first window shows: its tabs, and the private window.
    static func windowDidShow(_ controller: BrowserWindowController) {
        guard isRequested, !didSetUpWindow else { return }
        didSetUpWindow = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak controller] in
            guard let controller else { return }
            if has("tabs") { fill(controller) }
            if has("private") { _ = WindowManager.shared.openNewPrivateWindow() }
        }
    }

    private static func fill(_ controller: BrowserWindowController) {
        let pages = [
            "https://example.com/",
            "https://example.org/",
            "https://example.net/",
            "https://www.iana.org/help/example-domains?a-long-address=that-does-not-fit-in-the-address-bar&and=keeps-going-for-a-while",
        ]
        for (index, page) in pages.enumerated() {
            _ = controller.addTab(url: page, makeActive: index == pages.count - 1)
        }
        controller.pinTab(at: 0)
        controller.groupTabsForTest(at: [1, 2], name: "Reading", colorHex: "#34c759")
        // A new tab puts the keyboard in the address bar a moment after it
        // opens, and that keeps a hidden sidebar that holds the bar out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak controller] in
            controller?.window?.makeFirstResponder(nil)
        }
    }
}
