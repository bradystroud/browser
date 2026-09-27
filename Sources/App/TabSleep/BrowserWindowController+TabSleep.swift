import AppKit

extension BrowserWindowController {
    /// Window > Put Other Tabs to Sleep.
    @objc func sleepOtherTabs(_ sender: Any?) {
        let others = tabs.filter { $0 !== activeTab }
        TabSleepCoordinator.shared.sleepNow(others, in: self)
    }

    /// Whether Window > Put Other Tabs to Sleep has anything to do.
    var hasTabThatCanSleep: Bool {
        tabs.contains { TabSleepCoordinator.shared.canSleep($0, in: self) }
    }

    func tabStripView(_ tabStripView: TabStripView, didRequestSleepAt index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        guard TabSleepCoordinator.shared.canSleep(tab, in: self) else {
            NSSound.beep()
            return
        }
        TabSleepCoordinator.shared.sleepNow([tab], in: self)
    }
}
