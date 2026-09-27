import AppKit
import XCTest
@testable import WebKitAdapter

/// A copied password is marked for clipboard managers to skip and is taken
/// off again unless something else was copied since. Runs against a
/// private, uniquely named pasteboard -- never the user's real clipboard.
@MainActor
final class SensitivePasteboardTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.stroud.browser.tests.\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testCopyIsMarkedConcealedAndTransient() {
        SensitivePasteboard.copy("hunter2", to: pasteboard, clearAfter: 60)
        XCTAssertEqual(pasteboard.string(forType: .string), "hunter2")
        let types = pasteboard.types ?? []
        XCTAssertTrue(types.contains(SensitivePasteboard.concealedType))
        XCTAssertTrue(types.contains(SensitivePasteboard.transientType))
    }

    func testCopyIsClearedAfterTheDelay() {
        SensitivePasteboard.copy("hunter2", to: pasteboard, clearAfter: 0.2)
        settle(0.5)
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testQuittingClearsItEarly() {
        SensitivePasteboard.copy("hunter2", to: pasteboard, clearAfter: 60)
        // What the willTerminate observer runs. The notification itself
        // isn't posted: the engine adapter observes it too.
        SensitivePasteboard.clearPendingIfUnchanged()
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testQuittingLeavesSomethingCopiedSinceAlone() {
        SensitivePasteboard.copy("hunter2", to: pasteboard, clearAfter: 60)
        pasteboard.clearContents()
        pasteboard.setString("unrelated", forType: .string)
        SensitivePasteboard.clearPendingIfUnchanged()
        XCTAssertEqual(pasteboard.string(forType: .string), "unrelated")
    }

    func testSomethingCopiedSinceIsLeftAlone() {
        SensitivePasteboard.copy("hunter2", to: pasteboard, clearAfter: 0.2)
        pasteboard.clearContents()
        pasteboard.setString("unrelated", forType: .string)
        settle(0.5)
        XCTAssertEqual(pasteboard.string(forType: .string), "unrelated")
    }
}
