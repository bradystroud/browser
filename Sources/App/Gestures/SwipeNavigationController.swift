import AppKit

/// Two-finger trackpad swipe back/forward for an engine with no native
/// swipe (`EngineCapabilities.nativeSwipeNavigation` false -- CEF). WebKit
/// uses WKWebView's own gesture instead, and this never starts.
///
/// Scroll events are only read, never taken: the monitor hands every event
/// on untouched, so the page scrolls exactly as it would without this. A
/// local monitor rather than a scrollWheel override because the engine's
/// own view receives the events, and a monitor cannot block the run loop
/// the engine's message pump runs on.
///
/// The decisions themselves live in GestureCore's SwipeNavigationTracker;
/// this class only feeds it live-gesture events (never momentum, never a
/// phase-less mouse wheel), the page's answers from SwipeScrollProbeScript,
/// and draws what it says.
///
/// Honors System Settings > Trackpad > "Swipe between pages" through
/// NSEvent.isSwipeTrackingFromScrollEventsEnabled, the same switch
/// WKWebView's and Safari's swipe obey.
final class SwipeNavigationController {
    static let shared = SwipeNavigationController()

    private var monitor: Any?
    private var tracker = SwipeNavigationTracker()
    private weak var tab: Tab?
    private var indicator: SwipeIndicatorView?
    /// Tabs whose page last reported the pointer over a frame.
    private let pointerOverFrame = NSHashTable<Tab>.weakObjects()

    private init() {}

    func start() {
        guard SwipeScrollProbeScript.isNeeded, monitor == nil else { return }
        PageMessageDispatcher.shared.register(types: [SwipeScrollProbeScript.messageType]) { [weak self] message in
            message.tab.respondToPageMessage(requestId: message.requestId, success: true, response: "")
            self?.pageReported(message)
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return }
        switch event.phase {
        case .began:
            removeIndicator()
            guard NSEvent.isSwipeTrackingFromScrollEventsEnabled,
                  let tab = pageTab(under: event),
                  !pointerOverFrame.contains(tab)
            else {
                self.tab = nil
                _ = tracker.cancel()
                return
            }
            self.tab = tab
            tracker.begin(canGoBack: tab.canGoBack, canGoForward: tab.canGoForward)
            tab.executeJavaScript(SwipeScrollProbeScript.resetGesture(tracker.gesture))
        case .changed:
            guard tab != nil, tracker.isListening else { return }
            let fingerDeltaX = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            apply(tracker.change(fingerDeltaX: Double(fingerDeltaX), deltaY: Double(event.scrollingDeltaY), time: event.timestamp))
        case .ended:
            guard tab != nil else { return }
            apply(tracker.end(time: event.timestamp))
        case .cancelled:
            guard tab != nil else { return }
            apply(tracker.cancel())
        default:
            break
        }
    }

    private struct ProbeReport: Decodable {
        let taken: Bool?
        let gesture: Int?
        let overFrame: Bool?
    }

    private func pageReported(_ message: PageMessage) {
        guard let data = message.request.data(using: .utf8),
              let report = try? JSONDecoder().decode(ProbeReport.self, from: data)
        else { return }
        if let overFrame = report.overFrame {
            if overFrame {
                pointerOverFrame.add(message.tab)
            } else {
                pointerOverFrame.remove(message.tab)
            }
        }
        if let taken = report.taken, let gesture = report.gesture, message.tab === tab {
            apply(tracker.pageAnswered(scrollTaken: taken, gesture: gesture, time: ProcessInfo.processInfo.systemUptime))
        }
    }

    /// A new document starts with the pointer over nothing it has reported
    /// yet; the old document's "over a frame" must not outlive it.
    func documentDidStart(in tab: Tab) {
        pointerOverFrame.remove(tab)
    }

    /// The active tab of the window under the event, when the pointer is
    /// over its page (not its docked developer tools, not the toolbar).
    private func pageTab(under event: NSEvent) -> Tab? {
        guard let window = event.window,
              let controller = WindowManager.shared.windowControllers.first(where: { $0.window === window }),
              let tab = controller.activeTab
        else { return nil }
        let pageView = tab.devTools.pageView
        guard pageView.window === window, !pageView.isHiddenOrHasHiddenAncestor else { return nil }
        let point = pageView.convert(event.locationInWindow, from: nil)
        return pageView.bounds.contains(point) ? tab : nil
    }

    private func apply(_ effect: SwipeEffect) {
        if effect.armingChanged, effect.indicator != nil || indicator != nil {
            let armed = effect.indicator?.isArmed ?? false
            NSHapticFeedbackManager.defaultPerformer.perform(armed ? .levelChange : .alignment, performanceTime: .now)
        }
        if let direction = effect.navigation {
            if let state = effect.indicator { draw(state) }
            dismissIndicator(duration: 0.22, drift: direction == .back ? 12 : -12)
            switch direction {
            case .back: tab?.goBack()
            case .forward: tab?.goForward()
            }
            tab = nil
            return
        }
        if let state = effect.indicator {
            draw(state)
        } else if indicator != nil {
            dismissIndicator(duration: 0.16, drift: 0)
        }
    }

    private func draw(_ state: SwipeIndicatorState) {
        guard let tab else { return }
        let host = tab.hostView
        let pageFrame = host.convert(tab.devTools.pageView.bounds, from: tab.devTools.pageView)
        let view: SwipeIndicatorView
        if let existing = indicator, existing.superview === host {
            view = existing
        } else {
            removeIndicator()
            view = SwipeIndicatorView(frame: .zero)
            host.addSubview(view, positioned: .above, relativeTo: nil)
            indicator = view
        }
        view.alphaValue = 1
        view.show(state, in: pageFrame)
    }

    /// Fades the current indicator out and forgets it, so the next gesture
    /// starts with a fresh one rather than fading this one back in.
    private func dismissIndicator(duration: TimeInterval, drift: CGFloat) {
        guard let view = indicator else { return }
        indicator = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = 0
            if drift != 0 {
                view.animator().setFrameOrigin(NSPoint(x: view.frame.minX + drift, y: view.frame.minY))
            }
        }, completionHandler: {
            view.removeFromSuperview()
        })
    }

    private func removeIndicator() {
        indicator?.removeFromSuperview()
        indicator = nil
    }
}
