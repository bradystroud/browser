import AppKit

/// Manages one window's Tab Overview grid (⇧⌘\, browser-rhi.3) show/dismiss
/// lifecycle. Unlike ShortcutsOverlayController (one global singleton
/// overlay, content re-derived fresh from NSApp.mainMenu each time it
/// opens, not tied to any specific window's data), this is a
/// window-level feature -- each BrowserWindowController owns one instance,
/// since the grid shows *that* window's own tabs.
final class TabOverviewController {
    private weak var windowController: BrowserWindowController?
    private var overlayView: TabOverviewView?

    init(windowController: BrowserWindowController) {
        self.windowController = windowController
    }

    var isShowing: Bool { overlayView != nil }

    func toggle() {
        isShowing ? dismiss() : show()
    }

    private func show() {
        guard overlayView == nil, let windowController,
              let contentView = windowController.window?.contentView else { return }

        let view = TabOverviewView(frame: contentView.bounds)
        view.autoresizingMask = [.width, .height]
        contentView.addSubview(view)
        overlayView = view

        // "Collapsed-group tabs appear in the grid (overview reveals
        // everything)" -- every tab in windowController.tabs, not filtered
        // by visibleTabIndices the way strip cycling is.
        // cpuUsagePercent is read once here, matching this view's existing
        // "built once when shown; no live updates" design (see
        // TabOverviewView's own doc comment) -- not a live-refreshing
        // monitor, just a subtle snapshot indicator (browser-7jz.4). nil
        // when the engine has no per-tab figure, so no badge is shown.
        let readsCPU = ActiveEngine.capabilities.perTabCPUUsage
        let tabs = windowController.tabs.map { (id: $0.id, title: $0.title, favicon: $0.faviconImage, cpuUsagePercent: readsCPU ? $0.cpuUsagePercent() : nil) }
        view.configure(
            tabs: tabs,
            selectedTabId: windowController.activeTab?.id,
            asleepTabIds: Set(windowController.tabs.filter(\.isAsleep).map(\.id)),
            thumbnailProvider: { [weak windowController] tabId in windowController?.thumbnailImage(forTabId: tabId) },
            onSelect: { [weak self] tabId in self?.selectAndDismiss(tabId) },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        windowController.window?.makeFirstResponder(view)
    }

    private func selectAndDismiss(_ tabId: UUID) {
        if let index = windowController?.tabs.firstIndex(where: { $0.id == tabId }) {
            windowController?.selectTab(at: index)
        }
        dismiss()
    }

    func dismiss() {
        overlayView?.removeFromSuperview()
        overlayView = nil
    }
}
