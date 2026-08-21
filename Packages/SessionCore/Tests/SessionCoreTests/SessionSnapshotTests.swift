import Foundation
import Testing
@testable import SessionCore

/// `session.json` is written by one build and read by the next, so its
/// hand-written tolerant decoding is load-bearing: a key added by a later
/// feature must not stop an older file from loading, or the user loses every
/// window they had open. That decoding had no tests until browser-n2j moved
/// this type into a package where it could have some.
@Suite("session.json decodes files written by older builds")
struct SessionSnapshotBackCompatTests {
    private func snapshot(_ json: String) throws -> SessionSnapshot {
        try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
    }

    @Test("a file written before pinned tabs existed loads, with every tab unpinned")
    func missingIsPinned() throws {
        let decoded = try snapshot("""
        {"windows":[{"profileId":"p1","tabs":[{"url":"https://a.example","title":"A"}],"activeTabIndex":0}]}
        """)
        #expect(decoded.windows.first?.tabs.first?.isPinned == false)
    }

    @Test("a file written before tab groups existed loads, with no groups anywhere")
    func missingGroups() throws {
        let decoded = try snapshot("""
        {"windows":[{"profileId":"p1","tabs":[{"url":"https://a.example","title":"A"}],"activeTabIndex":0}]}
        """)
        let window = try #require(decoded.windows.first)
        #expect(window.groups == nil)
        #expect(window.tabs.first?.groupId == nil)
    }

    @Test("a window saved without a frame loads -- the frame has always been optional")
    func missingFrame() throws {
        let decoded = try snapshot("""
        {"windows":[{"profileId":"p1","tabs":[],"activeTabIndex":0}]}
        """)
        #expect(decoded.windows.first?.frame == nil)
    }

    @Test("a tab missing its url or title is a real failure, not something to paper over")
    func missingRequiredKeys() {
        #expect(throws: (any Error).self) {
            try snapshot("""
            {"windows":[{"profileId":"p1","tabs":[{"title":"A"}],"activeTabIndex":0}]}
            """)
        }
    }

    @Test("everything a current build writes survives a round trip")
    func roundTrip() throws {
        let group = UUID()
        let original = SessionSnapshot(windows: [
            SessionSnapshot.Window(
                profileId: "p1",
                frame: SessionSnapshot.WindowFrame(x: 10, y: 20, width: 800, height: 600),
                tabs: [
                    SessionSnapshot.Tab(url: "https://a.example", title: "A", isPinned: true, groupId: group),
                    SessionSnapshot.Tab(url: "https://b.example", title: "B"),
                ],
                activeTabIndex: 1,
                groups: [SessionSnapshot.Group(id: group, name: "Work", colorHex: "#ff0000", isCollapsed: false)]
            )
        ])

        let decoded = try JSONDecoder().decode(
            SessionSnapshot.self, from: JSONEncoder().encode(original)
        )
        let window = try #require(decoded.windows.first)
        #expect(window.tabs == original.windows[0].tabs)
        #expect(window.groups == original.windows[0].groups)
        #expect(window.frame == original.windows[0].frame)
        #expect(window.activeTabIndex == 1)
    }

    @Test("an explicitly false isPinned round-trips as false, not as an absent key")
    func explicitFalseIsPinned() throws {
        let encoded = try JSONEncoder().encode(
            SessionSnapshot.Tab(url: "https://a.example", title: "A", isPinned: false)
        )
        #expect(String(decoding: encoded, as: UTF8.self).contains("isPinned"))
    }
}
