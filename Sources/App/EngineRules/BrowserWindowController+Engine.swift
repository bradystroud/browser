import AppKit

/// Moving tabs between engines: the tab context menu's "Reopen in ..." and
/// "Always Open <site> in ...", and the same two commands in the View menu
/// for the active tab.
extension BrowserWindowController {
    func tabStripView(_ tabStripView: TabStripView, didRequestReopenAt index: Int, in engine: EngineChoice) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].reopen(in: engine)
    }

    func tabStripView(_ tabStripView: TabStripView, didRequestAlwaysOpenSiteAt index: Int, in engine: EngineChoice) {
        guard tabs.indices.contains(index) else { return }
        alwaysOpenSite(of: tabs[index], in: engine)
    }

    /// View > Reopen in WebKit/Chromium.
    @objc func reopenInOtherEngine(_ sender: Any?) {
        guard let tab = activeTab else { return }
        tab.reopen(in: tab.engine.other)
    }

    /// View > Always Open <site> in WebKit/Chromium.
    @objc func alwaysOpenSiteInOtherEngine(_ sender: Any?) {
        guard let tab = activeTab else { return }
        alwaysOpenSite(of: tab, in: tab.engine.other)
    }

    /// Writes (or retargets) the user's rule for the tab's site, then moves
    /// every open tab on that site into `engine` -- the rule now says so,
    /// and a tab left behind would contradict the menu item just chosen.
    private func alwaysOpenSite(of tab: Tab, in engine: EngineChoice) {
        guard let host = tab.siteHost else { return }
        EngineRulesStore.shared.setEngine(engine.siteEngine, forPattern: host)
        for window in WindowManager.shared.windowControllers {
            for other in window.tabs where other.siteHost == host && other.engine != engine {
                other.switchEngine(to: engine, url: other.urlString)
            }
        }
    }

    /// Titles and enables the two View menu items for the active tab.
    func validateEngineMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let tab = activeTab else { return false }
        let other = tab.engine.other.displayName
        if menuItem.action == #selector(reopenInOtherEngine(_:)) {
            menuItem.title = "Reopen in \(other)"
            return true
        }
        guard let host = tab.siteHost else {
            menuItem.title = "Always Open This Site in \(other)"
            return false
        }
        menuItem.title = "Always Open \(host) in \(other)"
        return true
    }
}
