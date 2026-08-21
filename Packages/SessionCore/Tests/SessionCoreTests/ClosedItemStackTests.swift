import Foundation
import Testing
@testable import SessionCore

private func tab(_ url: String, title: String = "", pinned: Bool = false, group: UUID? = nil) -> SessionSnapshot.Tab {
    SessionSnapshot.Tab(url: url, title: title, isPinned: pinned, groupId: group)
}

private func closedTab(
    _ url: String, profile: String = "p1", index: Int = 0, title: String = "", at seconds: TimeInterval = 0
) -> ClosedItem {
    .tab(ClosedTab(
        tab: tab(url, title: title), profileId: profile, index: index,
        closedAt: Date(timeIntervalSince1970: 1_700_000_000 + seconds)
    ))
}

private func closedWindow(
    urls: [String], profile: String = "p1", at seconds: TimeInterval = 0
) -> ClosedItem {
    .window(ClosedWindow(
        profileId: profile, tabs: urls.map { tab($0) }, groups: [], activeTabIndex: 0,
        frame: nil, closedAt: Date(timeIntervalSince1970: 1_700_000_000 + seconds)
    ))
}

@Suite("Recording closed items")
struct RecordingTests {
    @Test("the newest closed item comes back first")
    func newestFirst() {
        var stack = ClosedItemStack()
        stack.record(closedTab("https://a.example"), isPrivate: false)
        stack.record(closedTab("https://b.example"), isPrivate: false)

        let first = stack.popMostRecent(profileId: "p1")
        let second = stack.popMostRecent(profileId: "p1")
        let third = stack.popMostRecent(profileId: "p1")
        #expect(first == closedTab("https://b.example"))
        #expect(second == closedTab("https://a.example"))
        #expect(third == nil)
    }

    @Test("the same page closed twice is remembered twice -- it happened twice")
    func noDeduplication() {
        var stack = ClosedItemStack()
        stack.record(closedTab("https://a.example"), isPrivate: false)
        stack.record(closedTab("https://a.example"), isPrivate: false)

        #expect(stack.items.count == 2)
    }

    @Test("the oldest entry falls off the end once the stack is full")
    func evictsOldest() {
        var stack = ClosedItemStack(capacity: 3)
        for index in 0..<5 {
            stack.record(closedTab("https://\(index).example", at: TimeInterval(index)), isPrivate: false)
        }

        #expect(stack.items.count == 3)
        #expect(stack.items.map(\.menuTitle) == ["https://4.example", "https://3.example", "https://2.example"])
    }

    @Test("a capacity below one is not allowed to produce a stack that cannot hold anything")
    func capacityFloor() {
        var stack = ClosedItemStack(capacity: 0)
        let recorded = stack.record(closedTab("https://a.example"), isPrivate: false)
        #expect(recorded)
        #expect(stack.items.count == 1)
    }

    @Test("a stack built from more items than it can hold keeps the newest")
    func initTruncates() {
        let stack = ClosedItemStack(
            capacity: 2,
            items: [closedTab("https://a.example"), closedTab("https://b.example"), closedTab("https://c.example")]
        )
        #expect(stack.items.count == 2)
        #expect(stack.items.first == closedTab("https://a.example"))
    }
}

@Suite("Private browsing never enters the stack")
struct PrivacyTests {
    @Test("a tab closed in a private window is refused")
    func privateTabRefused() {
        var stack = ClosedItemStack()
        let recorded = stack.record(closedTab("https://secret.example"), isPrivate: true)
        #expect(!recorded)
        #expect(stack.items.isEmpty)
    }

    @Test("a private window is refused whole, tabs and all")
    func privateWindowRefused() {
        var stack = ClosedItemStack()
        let recorded = stack.record(closedWindow(urls: ["https://a.example", "https://b.example"]), isPrivate: true)
        #expect(!recorded)
        #expect(stack.items.isEmpty)
    }

    @Test("refusing a private item leaves everything already recorded alone")
    func refusalIsNotDestructive() {
        var stack = ClosedItemStack()
        stack.record(closedTab("https://a.example"), isPrivate: false)
        stack.record(closedTab("https://secret.example"), isPrivate: true)

        #expect(stack.items == [closedTab("https://a.example")])
    }

    @Test("nothing private survives a round trip through the file, because it was never stored")
    func nothingPrivateIsEncoded() throws {
        var stack = ClosedItemStack()
        stack.record(closedTab("https://secret.example"), isPrivate: true)

        let data = try JSONEncoder().encode(stack)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("secret.example"))
    }
}

@Suite("What is worth remembering")
struct WorthRememberingTests {
    @Test("only a real web address is remembered")
    func onlyHTTPTabs() {
        var stack = ClosedItemStack()
        let https = stack.record(closedTab("https://a.example"), isPrivate: false)
        let http = stack.record(closedTab("http://b.example"), isPrivate: false)
        // The start page reports an empty URL (see Tab.urlString), and a
        // data:/about: page has nothing to put back.
        let blank = stack.record(closedTab(""), isPrivate: false)
        let about = stack.record(closedTab("about:blank"), isPrivate: false)
        let data = stack.record(closedTab("data:text/html,"), isPrivate: false)
        #expect(https)
        #expect(http)
        #expect(!blank)
        #expect(!about)
        #expect(!data)
        #expect(stack.items.count == 2)
    }

    @Test("a window counts if any one of its tabs does, and keeps all of them")
    func windowWithOneRealTab() {
        var stack = ClosedItemStack()
        let recorded = stack.record(closedWindow(urls: ["", "https://a.example"]), isPrivate: false)
        #expect(recorded)

        guard case .window(let closed)? = stack.items.first else {
            Issue.record("expected a window entry")
            return
        }
        // Both tabs kept: the window should come back looking like the
        // window that was closed, blank tab included.
        #expect(closed.tabs.count == 2)
    }

    @Test("a window of nothing but blank tabs is not worth a press of the shortcut")
    func windowWithNothingReal() {
        var stack = ClosedItemStack()
        let recorded = stack.record(closedWindow(urls: ["", ""]), isPrivate: false)
        #expect(!recorded)
        #expect(stack.items.isEmpty)
    }
}

@Suite("Profiles stay separate")
struct ProfileScopingTests {
    @Test("reopening in one profile steps over another profile's entries without consuming them")
    func popSkipsOtherProfiles() {
        var stack = ClosedItemStack()
        stack.record(closedTab("https://work.example", profile: "work"), isPrivate: false)
        stack.record(closedTab("https://home.example", profile: "home"), isPrivate: false)

        let popped = stack.popMostRecent(profileId: "work")
        #expect(popped == closedTab("https://work.example", profile: "work"))
        // The other profile's entry is still there, untouched.
        #expect(stack.items == [closedTab("https://home.example", profile: "home")])
    }

    @Test("a profile with nothing closed gets nothing back")
    func popEmptyProfile() {
        var stack = ClosedItemStack()
        stack.record(closedTab("https://a.example", profile: "work"), isPrivate: false)

        let popped = stack.popMostRecent(profileId: "other")
        #expect(popped == nil)
        #expect(stack.items.count == 1)
    }

    @Test("picking a row out of the menu takes that row, counting within this profile only")
    func takeAtIndexIsProfileRelative() {
        var stack = ClosedItemStack()
        stack.record(closedTab("https://work-old.example", profile: "work"), isPrivate: false)
        stack.record(closedTab("https://home.example", profile: "home"), isPrivate: false)
        stack.record(closedTab("https://work-new.example", profile: "work"), isPrivate: false)

        // Index 1 in the "work" menu is work-old, even though it sits at
        // position 2 in the underlying stack with home's entry in between.
        let taken = stack.take(at: 1, profileId: "work")
        #expect(taken == closedTab("https://work-old.example", profile: "work"))
        #expect(stack.items.map(\.menuTitle) == ["https://work-new.example", "https://home.example"])
    }

    @Test("an index past the end of this profile's list gives back nothing")
    func takeAtOutOfRangeIndex() {
        var stack = ClosedItemStack()
        stack.record(closedTab("https://a.example", profile: "work"), isPrivate: false)

        let tooFar = stack.take(at: 1, profileId: "work")
        let negative = stack.take(at: -1, profileId: "work")
        let wrongProfile = stack.take(at: 0, profileId: "home")
        #expect(tooFar == nil)
        #expect(negative == nil)
        #expect(wrongProfile == nil)
        #expect(stack.items.count == 1)
    }

    @Test("the menu lists only this profile's entries, newest first, up to the limit")
    func recentItemsFiltersAndLimits() {
        var stack = ClosedItemStack()
        stack.record(closedTab("https://a.example", profile: "work"), isPrivate: false)
        stack.record(closedTab("https://b.example", profile: "home"), isPrivate: false)
        stack.record(closedTab("https://c.example", profile: "work"), isPrivate: false)

        #expect(stack.recentItems(profileId: "work").map(\.menuTitle) == ["https://c.example", "https://a.example"])
        #expect(stack.recentItems(profileId: "work", limit: 1).map(\.menuTitle) == ["https://c.example"])
    }
}

@Suite("Menu titles")
struct MenuTitleTests {
    @Test("a tab is named by its title, falling back to its URL")
    func tabTitles() {
        #expect(closedTab("https://a.example", title: "Hello").menuTitle == "Hello")
        #expect(closedTab("https://a.example").menuTitle == "https://a.example")
    }

    @Test("a window is named by how many tabs it had, singular and plural")
    func windowTitles() {
        #expect(closedWindow(urls: ["https://a.example"]).menuTitle == "Window (1 Tab)")
        #expect(closedWindow(urls: ["https://a.example", "https://b.example"]).menuTitle == "Window (2 Tabs)")
    }
}

@Suite("Persistence")
struct PersistenceTests {
    @Test("a stack survives a round trip through JSON with everything intact")
    func roundTrip() throws {
        let group = UUID()
        var stack = ClosedItemStack()
        stack.record(
            .tab(ClosedTab(
                tab: SessionSnapshot.Tab(url: "https://a.example", title: "A", isPinned: true, groupId: group),
                profileId: "p1", index: 3, closedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )),
            isPrivate: false
        )
        stack.record(closedWindow(urls: ["https://b.example", "https://c.example"]), isPrivate: false)

        let data = try JSONEncoder().encode(stack)
        let decoded = try JSONDecoder().decode(ClosedItemStack.self, from: data)

        #expect(decoded.items == stack.items)
        guard case .tab(let restored)? = decoded.items.last else {
            Issue.record("expected the tab entry to survive")
            return
        }
        #expect(restored.index == 3)
        #expect(restored.tab.isPinned)
        #expect(restored.tab.groupId == group)
    }

    @Test("the stored form names its kinds, so the file stays legible")
    func discriminatedForm() throws {
        var stack = ClosedItemStack()
        stack.record(closedTab("https://a.example"), isPrivate: false)

        let json = String(decoding: try JSONEncoder().encode(stack), as: UTF8.self)
        #expect(json.contains("\"kind\""))
        #expect(json.contains("\"tab\""))
        // Not the compiler's synthesized enum form.
        #expect(!json.contains("_0"))
    }

    @Test("one unreadable entry is skipped rather than costing the whole stack")
    func lossyDecoding() throws {
        // The middle entry is a kind this build has never heard of, as a
        // file written by a future build would contain.
        let json = """
        {"items":[
          {"kind":"tab","tab":{"tab":{"url":"https://a.example","title":"A","isPinned":false},"profileId":"p1","index":0,"closedAt":0}},
          {"kind":"somethingNew","payload":{}},
          {"kind":"tab","tab":{"tab":{"url":"https://b.example","title":"B","isPinned":false},"profileId":"p1","index":1,"closedAt":0}}
        ]}
        """
        let decoded = try JSONDecoder().decode(ClosedItemStack.self, from: Data(json.utf8))

        #expect(decoded.items.count == 2)
        #expect(decoded.items.map(\.menuTitle) == ["A", "B"])
    }

    @Test("a malformed entry of a known kind is skipped too")
    func malformedKnownKind() throws {
        let json = """
        {"items":[
          {"kind":"tab"},
          {"kind":"tab","tab":{"tab":{"url":"https://b.example","title":"B","isPinned":false},"profileId":"p1","index":1,"closedAt":0}}
        ]}
        """
        let decoded = try JSONDecoder().decode(ClosedItemStack.self, from: Data(json.utf8))
        #expect(decoded.items.map(\.menuTitle) == ["B"])
    }

    @Test("an empty or absent list decodes to an empty stack rather than failing")
    func emptyFile() throws {
        #expect(try JSONDecoder().decode(ClosedItemStack.self, from: Data("{}".utf8)).items.isEmpty)
        #expect(try JSONDecoder().decode(ClosedItemStack.self, from: Data(#"{"items":[]}"#.utf8)).items.isEmpty)
    }
}
