import AppKit
import XCTest
@testable import WebKitAdapter

/// The ⌥⇧-click recognizer behind link peek, and WebKit's "Peek Link"
/// context-menu item.
final class LinkPeekGestureTests: XCTestCase {
    func testOnlyExactlyOptionShiftIsAPeekClick() {
        XCTAssertTrue(LinkPeekGesture.isPeekClick([.option, .shift]))
        XCTAssertTrue(LinkPeekGesture.isPeekClick([.option, .shift, .capsLock]))
        XCTAssertFalse(LinkPeekGesture.isPeekClick(.shift))
        XCTAssertFalse(LinkPeekGesture.isPeekClick(.option))
        XCTAssertFalse(LinkPeekGesture.isPeekClick([.option, .shift, .command]))
        XCTAssertFalse(LinkPeekGesture.isPeekClick([]))
    }

    func testGestureIsConsumedOnceForItsOwnWindow() {
        var gesture = LinkPeekGesture()
        gesture.recordMouseDown(windowNumber: 7, modifiers: [.option, .shift], time: 100)
        XCTAssertFalse(gesture.consume(windowNumber: 8, now: 100.1))
        gesture.recordMouseDown(windowNumber: 7, modifiers: [.option, .shift], time: 100)
        XCTAssertTrue(gesture.consume(windowNumber: 7, now: 100.2))
        XCTAssertFalse(gesture.consume(windowNumber: 7, now: 100.3))
    }

    func testGestureExpires() {
        var gesture = LinkPeekGesture()
        gesture.recordMouseDown(windowNumber: 1, modifiers: [.option, .shift], time: 100)
        XCTAssertFalse(gesture.consume(windowNumber: 1, now: 100 + LinkPeekGesture.lifetime + 0.1))
    }

    func testOrdinaryClickCancelsPendingGesture() {
        var gesture = LinkPeekGesture()
        gesture.recordMouseDown(windowNumber: 1, modifiers: [.option, .shift], time: 100)
        gesture.recordMouseDown(windowNumber: 1, modifiers: .shift, time: 100.1)
        XCTAssertFalse(gesture.consume(windowNumber: 1, now: 100.2))
    }
}

final class WebKitLinkPeekMenuTests: XCTestCase {
    private final class Target: NSObject {
        @objc func peek(_ sender: Any?) {}
    }

    private func linkMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Link", action: nil, keyEquivalent: "")
        let newWindow = NSMenuItem(title: "Open Link in New Window", action: nil, keyEquivalent: "")
        newWindow.identifier = NSUserInterfaceItemIdentifier(WebKitLinkPeekMenu.openLinkInNewWindowIdentifier)
        menu.addItem(newWindow)
        return menu
    }

    func testInsertsPeekAboveOpenInNewWindowCarryingIt() throws {
        let menu = linkMenu()
        let target = Target()
        let item = try XCTUnwrap(WebKitLinkPeekMenu.insertPeekItem(into: menu, target: target, action: #selector(Target.peek(_:))))
        XCTAssertEqual(menu.items.map(\.title), ["Open Link", "Peek Link", "Open Link in New Window"])
        XCTAssertTrue((item.representedObject as? NSMenuItem) === menu.items[2])
        XCTAssertTrue(item.target === target)
    }

    func testNoItemWithoutALinkOrTwice() {
        let target = Target()
        let plain = NSMenu()
        plain.addItem(withTitle: "Reload", action: nil, keyEquivalent: "")
        XCTAssertNil(WebKitLinkPeekMenu.insertPeekItem(into: plain, target: target, action: #selector(Target.peek(_:))))

        let menu = linkMenu()
        WebKitLinkPeekMenu.insertPeekItem(into: menu, target: target, action: #selector(Target.peek(_:)))
        XCTAssertNil(WebKitLinkPeekMenu.insertPeekItem(into: menu, target: target, action: #selector(Target.peek(_:))))
        XCTAssertEqual(menu.items.filter { $0.title == WebKitLinkPeekMenu.peekItemTitle }.count, 1)
    }

    func testArmingIsShortLived() {
        let now = Date()
        XCTAssertFalse(WebKitLinkPeekMenu.isArmed(since: nil, now: now))
        XCTAssertTrue(WebKitLinkPeekMenu.isArmed(since: now.addingTimeInterval(-0.5), now: now))
        XCTAssertFalse(WebKitLinkPeekMenu.isArmed(since: now.addingTimeInterval(-(WebKitLinkPeekMenu.armingLifetime + 1)), now: now))
    }
}
