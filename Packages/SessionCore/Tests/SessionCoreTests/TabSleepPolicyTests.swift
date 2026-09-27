import Foundation
import Testing
@testable import SessionCore

@Suite("Which tabs may be put to sleep")
struct TabSleepPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let idle: TimeInterval = 30 * 60

    private func idleTab(_ change: (inout TabSleepCandidate) -> Void = { _ in }) -> TabSleepCandidate {
        var candidate = TabSleepCandidate(lastUsed: now.addingTimeInterval(-idle - 1))
        change(&candidate)
        return candidate
    }

    private func automatic(_ candidate: TabSleepCandidate) -> TabSleepBlocker? {
        TabSleepPolicy.blocker(for: candidate, trigger: .automatic, now: now, idleInterval: idle)
    }

    private func manual(_ candidate: TabSleepCandidate) -> TabSleepBlocker? {
        TabSleepPolicy.blocker(for: candidate, trigger: .manual, now: now, idleInterval: idle)
    }

    @Test("a background tab idle past the interval sleeps")
    func idleSleeps() {
        #expect(automatic(idleTab()) == nil)
    }

    @Test("a tab looked at within the interval stays awake")
    func recentStaysAwake() {
        let recent = idleTab { $0.lastUsed = now.addingTimeInterval(-idle + 1) }
        #expect(automatic(recent) == .recentlyUsed)
    }

    @Test("hard guards hold for automatic and manual sleep alike")
    func hardGuards() {
        let cases: [(WritableKeyPath<TabSleepCandidate, Bool>, TabSleepBlocker)] = [
            (\.isAsleep, .alreadyAsleep),
            (\.isSelected, .selected),
            (\.isPrivate, .privateBrowsing),
            (\.hasDevToolsOpen, .devToolsOpen),
            (\.hasResponsiveDesignMode, .responsiveDesignMode),
            (\.hasActiveDownload, .downloading),
            (\.isAudible, .playingAudio),
            (\.hasLiveOpenedPopup, .openedLivePopup),
        ]
        for (flag, expected) in cases {
            let candidate = idleTab { $0[keyPath: flag] = true }
            #expect(automatic(candidate) == expected)
            #expect(manual(candidate) == expected)
        }
    }

    @Test("pinned and loading tabs stay awake automatically but sleep when asked")
    func softGuards() {
        #expect(automatic(idleTab { $0.isPinned = true }) == .pinned)
        #expect(manual(idleTab { $0.isPinned = true }) == nil)
        #expect(automatic(idleTab { $0.isLoading = true }) == .loading)
        #expect(manual(idleTab { $0.isLoading = true }) == nil)
    }

    @Test("asking by hand waives the idle clock")
    func manualIgnoresIdle() {
        #expect(manual(idleTab { $0.lastUsed = now }) == nil)
    }

    @Test("the page's own state can keep it awake")
    func pageGuards() {
        #expect(TabSleepPolicy.blocker(for: TabSleepPageState()) == nil)
        #expect(TabSleepPolicy.blocker(for: TabSleepPageState(hasUnsavedInput: true)) == .unsavedInput)
        #expect(TabSleepPolicy.blocker(for: TabSleepPageState(isInPictureInPicture: true)) == .pictureInPicture)
        #expect(TabSleepPolicy.blocker(for: TabSleepPageState(scrollY: 400)) == nil)
    }

    @Test("memory pressure only ever shortens the interval")
    func memoryPressure() {
        #expect(TabSleepPolicy.idleInterval(configured: idle, pressure: .normal) == idle)
        #expect(TabSleepPolicy.idleInterval(configured: idle, pressure: .warning) == TabSleepPolicy.warningIdleInterval)
        #expect(TabSleepPolicy.idleInterval(configured: 60, pressure: .warning) == 60)
        #expect(TabSleepPolicy.idleInterval(configured: idle, pressure: .critical) == 0)
    }

    @Test("the sweep runs between every five seconds and every minute")
    func sweepInterval() {
        #expect(TabSleepPolicy.sweepInterval(forIdleInterval: idle) == 60)
        #expect(TabSleepPolicy.sweepInterval(forIdleInterval: 40) == 10)
        #expect(TabSleepPolicy.sweepInterval(forIdleInterval: 4) == 5)
    }
}

@Suite("Reading the page's sleep marker")
struct TabSleepPageScriptTests {
    private func html(_ attributes: String, body: String = "") -> String {
        "<html lang=\"en\" \(attributes)><head></head><body>\(body)</body></html>"
    }

    @Test("a page that never ran the script holds nothing")
    func noMarker() {
        #expect(TabSleepPageScript.pageState(fromSource: html("")) == TabSleepPageState())
        #expect(TabSleepPageScript.pageState(fromSource: "") == TabSleepPageState())
    }

    @Test("every field is read")
    func fullMarker() {
        let state = TabSleepPageScript.pageState(fromSource: html("data-brw-sleep-state=\"input=1;unload=1;pip=1;y=1234\""))
        #expect(state == TabSleepPageState(hasUnsavedInput: true, isInPictureInPicture: true, hasBeforeUnloadHandler: true, scrollY: 1234))
    }

    @Test("a beforeunload guard keeps the page awake")
    func beforeUnload() {
        let state = TabSleepPageScript.pageState(fromSource: html("data-brw-sleep-state=\"input=0;unload=1;pip=0;y=0\""))
        #expect(TabSleepPolicy.blocker(for: state) == .beforeUnloadGuard)
    }

    @Test("an <html> tag inside a conditional comment is skipped for the real one")
    func conditionalComment() {
        let source = "<!DOCTYPE html><!--[if lt IE 9]><html class=\"ie8\"><![endif]--><html data-brw-sleep-state=\"input=1;unload=0;pip=0;y=0\"><body></body></html>"
        #expect(TabSleepPageScript.pageState(fromSource: source).hasUnsavedInput)
    }

    @Test("an unterminated comment before the root reports nothing held")
    func unterminatedComment() {
        #expect(TabSleepPageScript.pageState(fromSource: "<!-- <html data-brw-sleep-state=\"input=1\">") == TabSleepPageState())
    }

    @Test("a quiet page reports its scroll offset only")
    func quietMarker() {
        let state = TabSleepPageScript.pageState(fromSource: html("data-brw-sleep-state=\"input=0;pip=0;y=0\""))
        #expect(state == TabSleepPageState(scrollY: 0))
    }

    @Test("the attribute counts only on the html tag, not in the page's text")
    func onlyOnHTMLTag() {
        let source = html("", body: "data-brw-sleep-state=\"input=1;pip=1;y=9\"")
        #expect(TabSleepPageScript.pageState(fromSource: source) == TabSleepPageState())
    }

    @Test("malformed values are ignored rather than trusted")
    func malformed() {
        let state = TabSleepPageScript.pageState(fromSource: html("data-brw-sleep-state=\"input=yes;y=-5;junk\""))
        #expect(state == TabSleepPageState())
    }

    @Test("the marker the script writes is the one the reader looks for")
    func scriptUsesMarker() {
        #expect(TabSleepPageScript.source.contains(TabSleepPageScript.markerAttribute))
    }
}
