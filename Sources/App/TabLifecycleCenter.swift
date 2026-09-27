import AppKit

/// What happened to a tab. Posted by BrowserWindowController (the only thing
/// that ever creates, activates or closes a Tab) and by its TabDelegate
/// conformance (navigation/loading), and delivered to every registered
/// TabLifecycleObserver.
enum TabLifecycleEvent {
    /// The Tab has joined `controller.tabs`, or is a link peek's page about
    /// to be shown (LinkPeekController), which gets `opened` again if it is
    /// opened as a tab. A new Tab has no engine-side browser yet
    /// (Tab.createBrowserIfNeeded hasn't run) -- so an observer that wires
    /// per-tab plumbing here is guaranteed to be wired before the tab's page
    /// can possibly say anything. See PageMessageDispatcher for why that
    /// guarantee is the whole point of this event existing. A tab moved in
    /// live (BrowserWindowController.adoptTab) already has one, and may
    /// already have had `opened`, so handling it must be idempotent.
    case opened

    /// This tab is now its window's visible tab. Also fires for a brand-new
    /// tab created with makeActive (immediately after `opened`) and for
    /// whichever tab inherits activation when the active one is closed.
    case becameActive

    /// The tab's main-frame URL changed -- including an in-page,
    /// same-document change (history.pushState), not just a committed load.
    /// `tab.urlString` already reports the new value when this fires.
    case navigated

    /// The tab's main-frame load stopped, whether it succeeded or failed
    /// (the engine reports no distinction here -- see
    /// Tab.engineTabDidChangeLoadingState).
    case finishedLoading

    /// The tab has been removed from its window and its engine-side browser
    /// closed. `controller.tabs` no longer contains it.
    case closed
}

/// One method rather than five: every consumer of this cares about two or
/// three of the events and ignores the rest, which reads better as a single
/// `switch` with an explicit `default` than as four empty protocol-extension
/// stubs per conformer.
protocol TabLifecycleObserver: AnyObject {
    func tabLifecycleEvent(_ event: TabLifecycleEvent, tab: Tab, in controller: BrowserWindowController)
}

/// The app-wide broadcast point for tab lifecycle events (browser-g6d).
///
/// Before this existed, five separate feature controllers each ran their own
/// 0.4-1.5s Timer whose real job was tab *discovery* -- walking
/// WindowManager.shared.windowControllers looking for tabs they hadn't seen
/// yet, or for "is this still the active tab" -- because Tabs are only ever
/// constructed inside BrowserWindowController, which was treated as off
/// limits at the time each of those features was written. There was a real
/// correctness cost to that, not just a wasted-wakeups one:
/// PageMessageDispatcher's poll meant a page that sent a cefQuery before the
/// next tick had its message dropped in complete silence (nothing answers the
/// query, so neither onSuccess nor onFailure runs in the page).
///
/// Observers are held weakly and are never required to unregister; a
/// deallocated observer simply stops being visited. Everything here is
/// main-thread only -- every poster is AppKit UI code and every consumer
/// touches AppKit views.
final class TabLifecycleCenter {
    static let shared = TabLifecycleCenter()

    private let observers = NSHashTable<AnyObject>.weakObjects()

    private init() {}

    /// Idempotent: registering the same observer twice still delivers each
    /// event to it once (NSHashTable is a set).
    func addObserver(_ observer: TabLifecycleObserver) {
        observers.add(observer)
    }

    func post(_ event: TabLifecycleEvent, tab: Tab, in controller: BrowserWindowController) {
        assert(Thread.isMainThread, "TabLifecycleCenter is main-thread only")
        // allObjects is a snapshot, so an observer that opens/closes a tab in
        // response can't invalidate this iteration.
        for case let observer as TabLifecycleObserver in observers.allObjects {
            observer.tabLifecycleEvent(event, tab: tab, in: controller)
        }
    }
}
