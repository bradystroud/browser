import XCTest
@testable import WebEngineCore

final class CEFExtensionLifecycleTests: XCTestCase {
    typealias L = CEFExtensionLifecycle

    private func confirm(_ events: [L.Event], record: L.Record?, ranBefore: Bool = false, version: String, session: String) -> L.Record? {
        var record = record
        for event in events {
            record = L.confirming(event.token(version: version, session: session), record: record, ranBefore: ranBefore,
                                  version: version, session: session)
        }
        return record
    }

    func testFirstRunIsInstallOnlyThenNothingThatSession() {
        let due = L.due(record: nil, ranBefore: false, version: "1.0", session: "s1")
        XCTAssertEqual(due, [.installed])
        let record = confirm(due, record: nil, version: "1.0", session: "s1")
        XCTAssertEqual(record, L.Record(installedVersion: "1.0", startupSession: "s1"))
        XCTAssertEqual(L.due(record: record, ranBefore: false, version: "1.0", session: "s1"), [])
    }

    func testNextLaunchIsStartupOnlyNeverInstallAgain() {
        let record = L.Record(installedVersion: "1.0", startupSession: "s1")
        let due = L.due(record: record, ranBefore: true, version: "1.0", session: "s2")
        XCTAssertEqual(due, [.startup])
        let after = confirm(due, record: record, ranBefore: true, version: "1.0", session: "s2")
        XCTAssertEqual(L.due(record: after, ranBefore: true, version: "1.0", session: "s2"), [])
    }

    func testStoreUpdateGivesUpdateWithPreviousVersionAndStartup() {
        let record = L.Record(installedVersion: "1.0", startupSession: "s1")
        let due = L.due(record: record, ranBefore: true, version: "1.1", session: "s2")
        XCTAssertEqual(due, [.updated(previousVersion: "1.0"), .startup])
        let after = confirm(due, record: record, ranBefore: true, version: "1.1", session: "s2")
        XCTAssertEqual(after?.installedVersion, "1.1")
        XCTAssertEqual(L.due(record: after, ranBefore: true, version: "1.1", session: "s3"), [.startup])
    }

    func testShimOrRevisionChangeIsNotAnUpdate() {
        // The record holds the store version; a new shim or content revision
        // leaves it unchanged, so only onStartup is due.
        let record = L.Record(installedVersion: "1.0", startupSession: "s1")
        XCTAssertEqual(L.due(record: record, ranBefore: true, version: "1.0", session: "s2"), [.startup])
    }

    func testUnconfirmedEventsAreOfferedAgainAcrossLaunches() {
        XCTAssertEqual(L.due(record: nil, ranBefore: false, version: "1.0", session: "s1"), [.installed])
        // Never confirmed in s1 (the worker never started): still install in s2.
        XCTAssertEqual(L.due(record: nil, ranBefore: false, version: "1.0", session: "s2"), [.installed])
        let record = L.Record(installedVersion: "1.0", startupSession: "s1")
        let pending = L.due(record: record, ranBefore: true, version: "2.0", session: "s2")
        // Only the startup was confirmed: the update stays due.
        let partly = confirm([.startup], record: record, ranBefore: true, version: "2.0", session: "s2")
        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(L.due(record: partly, ranBefore: true, version: "2.0", session: "s2"), [.updated(previousVersion: "1.0")])
        XCTAssertEqual(L.due(record: partly, ranBefore: true, version: "2.0", session: "s3"), [.updated(previousVersion: "1.0"), .startup])
    }

    func testStaleOrUnknownTokensChangeNothing() {
        let record = L.Record(installedVersion: "1.0", startupSession: "s1")
        XCTAssertEqual(L.confirming("startup@s1", record: record, ranBefore: true, version: "1.0", session: "s2"), record)
        XCTAssertEqual(L.confirming("install@1.0", record: record, ranBefore: true, version: "1.0", session: "s2"), record)
        XCTAssertEqual(L.confirming("update@0.9>1.0", record: record, ranBefore: true, version: "1.0", session: "s2"), record)
        XCTAssertEqual(L.confirming("nonsense", record: nil, ranBefore: false, version: "1.0", session: "s2"), nil)
    }

    func testExtensionThatRanBeforeRecordsExistedGetsNoInstall() {
        XCTAssertEqual(L.due(record: nil, ranBefore: true, version: "1.0", session: "s1"), [.startup])
        let after = confirm([.startup], record: nil, ranBefore: true, version: "1.0", session: "s1")
        XCTAssertEqual(after, L.Record(installedVersion: "1.0", startupSession: "s1"))
    }

    func testTokensNameWhatTheyWereDecidedFor() {
        XCTAssertEqual(L.Event.installed.token(version: "1.0", session: "s"), "install@1.0")
        XCTAssertEqual(L.Event.updated(previousVersion: "1.0").token(version: "1.1", session: "s"), "update@1.0>1.1")
        XCTAssertEqual(L.Event.startup.token(version: "1.0", session: "s"), "startup@s")
    }

    func testStateWithoutLifecycleFieldDecodesAsLegacy() throws {
        let legacy = try JSONDecoder().decode(CEFExtensionProfileState.self, from: Data(#"{"current":{},"known":["x"]}"#.utf8))
        XCTAssertNil(legacy.lifecycle)
        XCTAssertEqual(CEFExtensionProfileState().lifecycle, [:])
    }
}
