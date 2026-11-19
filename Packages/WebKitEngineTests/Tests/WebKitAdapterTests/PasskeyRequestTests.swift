import XCTest
@testable import WebKitAdapter

/// Runs `WebKitPasskeyScript` against a stand-in credentials container that
/// records each request and settles it only when told to or when its signal
/// aborts, which is how the real one behaves while the agent holds the
/// request. The real one refuses every request in this unsigned test bundle.
final class PasskeyRequestTests: WebKitTabTestCase {
    override func routes() -> [String: LocalHTTPServer.Response] {
        ["/page": .html("<!DOCTYPE html><title>Passkeys</title><input autocomplete=\"username webauthn\">")]
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        loadAndWaitForCommit(server.url("/page"))
        _ = try callJS("""
            window.vis = 'visible';
            Object.defineProperty(document, 'visibilityState', { get: () => window.vis, configurable: true });
            window.calls = [];
            window.results = {};
            function Fake() {}
            const record = (kind, options) => {
              const call = { kind, mediation: options.mediation || 'optional', state: 'open',
                             ownSignal: !!options.signal && options.signal !== window.pageSignal };
              calls.push(call);
              return new Promise((resolve, reject) => {
                call.resolve = value => { call.state = 'resolved'; resolve(value); };
                call.fail = error => { call.state = 'failed'; reject(error); };
                if (options.signal) options.signal.addEventListener('abort', () => {
                  if (call.state === 'open') { call.state = 'aborted'; reject(options.signal.reason); }
                });
              });
            };
            Fake.prototype.get = function (options) { return record('get', options); };
            Fake.prototype.create = function (options) { return record('create', options); };
            (0, eval)('(' + body + ')')('__passkeyTestHook', Fake.prototype, 0);
            window.fake = new Fake();
            window.track = (name, promise) => {
              results[name] = 'pending';
              promise.then(value => { results[name] = 'resolved:' + value; },
                           error => { results[name] = 'rejected:' + (error && error.name || error); });
            };
            window.conditional = (signal) => fake.get({ mediation: 'conditional', signal, publicKey: { challenge: new Uint8Array(1) } });
            window.modal = () => fake.get({ publicKey: { challenge: new Uint8Array(1) } });
            window.setVisible = visible => { vis = visible ? 'visible' : 'hidden'; document.dispatchEvent(new Event('visibilitychange')); };
            """, arguments: ["body": WebKitPasskeyScript.body])
    }

    /// The states of every request the stand-in saw, in order.
    private func calls() throws -> [String] {
        try callJS("return calls.map(c => c.kind + '/' + c.mediation + '/' + c.state)") as? [String] ?? []
    }

    private func result(_ name: String) throws -> String? {
        try callJS("return results[\(name.debugDescription)] || null") as? String
    }

    /// Gives the script's restart timer and the page's promise callbacks a turn.
    private func turn() throws {
        _ = try callJS("await new Promise(r => setTimeout(r, 20));")
    }

    func testTabWrapsTheRealCredentialsContainer() throws {
        let wrapped = try callJS("""
            return navigator.credentials.get.name === 'get'
              && Object.getOwnPropertyNames(window).some(n => n.startsWith('__brwPasskeys'));
            """) as? Bool
        XCTAssertEqual(wrapped, true)
    }

    func testModalRequestSuspendsConditionalAndConditionalResumesAfter() throws {
        _ = try callJS("track('cond', conditional());")
        try turn()
        _ = try callJS("track('modal', modal());")
        try turn()
        XCTAssertEqual(try calls(), ["get/conditional/aborted", "get/optional/open"])
        XCTAssertEqual(try result("cond"), "pending", "the page's conditional promise must not see the suspension")

        _ = try callJS("calls[1].fail(new DOMException('cancelled', 'NotAllowedError'));")
        try turn()
        XCTAssertEqual(try result("modal"), "rejected:NotAllowedError")
        XCTAssertEqual(try calls(), ["get/conditional/aborted", "get/optional/failed", "get/conditional/open"])
        XCTAssertEqual(try result("cond"), "pending")

        _ = try callJS("calls[2].resolve('credential');")
        try turn()
        XCTAssertEqual(try result("cond"), "resolved:credential")
    }

    func testRegistrationAlsoSuspendsConditional() throws {
        _ = try callJS("track('cond', conditional());")
        try turn()
        _ = try callJS("track('create', fake.create({ publicKey: {} }));")
        try turn()
        XCTAssertEqual(try calls(), ["get/conditional/aborted", "create/optional/open"])
    }

    func testSecondModalRequestEndsTheFirst() throws {
        _ = try callJS("track('first', modal()); track('second', modal());")
        try turn()
        XCTAssertEqual(try calls(), ["get/optional/aborted", "get/optional/open"])
        XCTAssertEqual(try result("first"), "rejected:AbortError")
        XCTAssertEqual(try result("second"), "pending")
    }

    func testHiddenDocumentSuspendsConditionalUntilShown() throws {
        _ = try callJS("track('cond', conditional());")
        try turn()
        _ = try callJS("setVisible(false);")
        try turn()
        XCTAssertEqual(try calls(), ["get/conditional/aborted"])

        _ = try callJS("setVisible(true);")
        try turn()
        XCTAssertEqual(try calls(), ["get/conditional/aborted", "get/conditional/open"])
        XCTAssertEqual(try result("cond"), "pending")
    }

    func testConditionalStartedWhileHiddenWaitsUntilShown() throws {
        _ = try callJS("setVisible(false); track('cond', conditional());")
        try turn()
        XCTAssertEqual(try calls(), [])
        _ = try callJS("setVisible(true);")
        try turn()
        XCTAssertEqual(try calls(), ["get/conditional/open"])
    }

    func testPageHideEndsRequestsAndPageShowRestartsConditional() throws {
        _ = try callJS("track('cond', conditional());")
        try turn()
        _ = try callJS("""
            track('modal', modal());
            window.dispatchEvent(new PageTransitionEvent('pagehide', { persisted: true }));
            """)
        try turn()
        XCTAssertEqual(try calls(), ["get/conditional/aborted", "get/optional/aborted"])

        _ = try callJS("window.dispatchEvent(new PageTransitionEvent('pageshow', { persisted: true }));")
        try turn()
        XCTAssertEqual(try calls(), ["get/conditional/aborted", "get/optional/aborted", "get/conditional/open"])
    }

    func testCloseHookEndsEverythingForGood() throws {
        _ = try callJS("track('cond', conditional());")
        try turn()
        _ = try callJS("window.__passkeyTestHook(); setVisible(false); setVisible(true);")
        try turn()
        XCTAssertEqual(try calls(), ["get/conditional/aborted"])
    }

    func testPageAbortRejectsWithThePageReasonAndNeverRestarts() throws {
        _ = try callJS("""
            window.pageCtl = new AbortController();
            track('cond', conditional(pageCtl.signal));
            """)
        try turn()
        _ = try callJS("""
            pageCtl.abort(new DOMException('page', 'AbortError'));
            setVisible(false); setVisible(true);
            """)
        try turn()
        XCTAssertEqual(try result("cond"), "rejected:AbortError")
        XCTAssertEqual(try calls(), ["get/conditional/aborted"])
    }

    func testNewConditionalReplacesTheOld() throws {
        _ = try callJS("track('old', conditional());")
        try turn()
        _ = try callJS("track('new', conditional());")
        try turn()
        XCTAssertEqual(try calls(), ["get/conditional/aborted", "get/conditional/open"])
        XCTAssertEqual(try result("old"), "pending")
        XCTAssertEqual(try result("new"), "pending")
    }

    func testConditionalNeverStartsInTheSameTurn() throws {
        let started = try callJS("conditional(); return calls.length") as? Int
        XCTAssertEqual(started, 0)
        try turn()
        XCTAssertEqual(try calls(), ["get/conditional/open"])
    }

    func testRequestsGetASignalOfTheirOwn() throws {
        _ = try callJS("window.pageSignal = new AbortController().signal; modal(); fake.get({ publicKey: {}, signal: pageSignal });")
        let own = try callJS("return calls.map(c => c.ownSignal)") as? [Bool]
        XCTAssertEqual(own, [true, true])
    }

    func testOtherCredentialTypesPassThrough() throws {
        _ = try callJS("window.pageSignal = new AbortController().signal; fake.get({ password: true, signal: pageSignal });")
        let own = try callJS("return calls.map(c => c.ownSignal)") as? [Bool]
        XCTAssertEqual(own, [false])
    }
}
