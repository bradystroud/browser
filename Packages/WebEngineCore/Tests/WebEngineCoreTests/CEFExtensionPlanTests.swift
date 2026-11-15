import XCTest
@testable import WebEngineCore

final class CEFExtensionPlanTests: XCTestCase {
    private let fixtureID = "pgmnddkfhcbihfijmfgancppilgkimei"
    private var key: Data!

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "fixture-hello", withExtension: "crx", subdirectory: "Fixtures"))
        key = try Crx3.verifiedPackage(Data(contentsOf: url), expectedID: fixtureID).publicKey
    }

    private func store(enabled: Bool = true, version: String = "1.0", key: Data? = nil) -> InstalledWebExtension {
        InstalledWebExtension(id: fixtureID, source: .webStore, name: "Hello", version: version, enabled: enabled,
                              grants: [], publicKey: key?.base64EncodedString())
    }

    private func unpacked(path: String = "/dev/hello") -> InstalledWebExtension {
        InstalledWebExtension(id: fixtureID, source: .unpacked, name: "Hello", version: "1.0", unpackedPath: path, grants: [])
    }

    private func facts(exists: Bool = true, manifestKey: Data? = nil, refusal: CEFExtensionPolicy.Refusal? = nil,
                       stamp: String? = nil) -> CEFExtensionSourceFacts {
        CEFExtensionSourceFacts(folder: "/p/Extensions/\(fixtureID)", folderExists: exists, manifestKey: manifestKey,
                                refusal: refusal, treeStamp: stamp)
    }

    // MARK: - Planner

    func testStoreInstallWithKeyRuns() throws {
        let build = try XCTUnwrap(CEFExtensionPlanner.decide(store(key: key), facts: facts()).build)
        XCTAssertEqual(build.id, fixtureID)
        XCTAssertEqual(build.publicKey, key)
        XCTAssertTrue(build.fingerprint.hasPrefix("store|1.0|shim\(CEFExtensionShim.version)|"))
    }

    func testDisabledComesFirst() {
        XCTAssertEqual(CEFExtensionPlanner.decide(store(enabled: false), facts: facts(exists: false)), .disabled)
    }

    func testStoreInstallWithoutKeyWaitsForIt() {
        XCTAssertEqual(CEFExtensionPlanner.decide(store(key: nil), facts: facts()), .waitingForKey)
    }

    func testMissingFolderAndRefusal() {
        XCTAssertEqual(CEFExtensionPlanner.decide(store(key: key), facts: facts(exists: false)),
                       .unavailable(CEFExtensionPlanner.missingFolder))
        XCTAssertEqual(CEFExtensionPlanner.decide(store(key: key), facts: facts(refusal: .debuggerPermission)),
                       .unavailable(CEFExtensionPolicy.Refusal.debuggerPermission.message))
    }

    func testKeyThatIsNotTheIdsIsRefused() {
        let other = Data(repeating: 7, count: 300)
        XCTAssertEqual(CEFExtensionPlanner.decide(store(key: other), facts: facts()), .unavailable(CEFExtensionPlanner.keyMismatch))
    }

    func testUnpackedNeedsAPinnedKey() {
        XCTAssertEqual(CEFExtensionPlanner.decide(unpacked(), facts: facts()), .unavailable(CEFExtensionPlanner.unpackedWithoutKey))
        XCTAssertNotNil(CEFExtensionPlanner.decide(unpacked(), facts: facts(manifestKey: key)).build)
    }

    func testFingerprintFollowsVersionShimAndTree() throws {
        let one = try XCTUnwrap(CEFExtensionPlanner.decide(store(version: "1.0", key: key), facts: facts()).build).fingerprint
        let two = try XCTUnwrap(CEFExtensionPlanner.decide(store(version: "1.1", key: key), facts: facts()).build).fingerprint
        let shim = try XCTUnwrap(CEFExtensionPlanner.decide(store(version: "1.0", key: key), facts: facts(), shimVersion: 99).build).fingerprint
        XCTAssertNotEqual(one, two)
        XCTAssertNotEqual(one, shim)
        // A store folder changes only with its version: a stamp is ignored.
        let stamped = try XCTUnwrap(CEFExtensionPlanner.decide(store(version: "1.0", key: key), facts: facts(stamp: "x")).build).fingerprint
        XCTAssertEqual(one, stamped)

        let a = try XCTUnwrap(CEFExtensionPlanner.decide(unpacked(), facts: facts(manifestKey: key, stamp: "a")).build).fingerprint
        let b = try XCTUnwrap(CEFExtensionPlanner.decide(unpacked(), facts: facts(manifestKey: key, stamp: "b")).build).fingerprint
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Folders

    private func build(_ fingerprint: String, id: String? = nil) -> CEFExtensionBuild {
        CEFExtensionBuild(id: id ?? fixtureID, sourceFolder: "/s", publicKey: key, fingerprint: fingerprint)
    }

    func testUnchangedCopyIsReused() {
        let state = CEFExtensionProfileState(current: [fixtureID: .init(folder: "v1-s1-a", fingerprint: "F")], known: [fixtureID])
        let plan = CEFExtensionFolderPlan.make(state: state, builds: [build("F")], installed: [fixtureID],
                                               foldersOnDisk: [fixtureID: ["v1-s1-a"]], newName: { _ in "new" })
        XCTAssertEqual(plan.reuse, [fixtureID: "v1-s1-a"])
        XCTAssertTrue(plan.prepare.isEmpty)
        XCTAssertTrue(plan.deleteData.isEmpty)
    }

    func testChangedCopyGoesToANewFolderNeverTheCurrentOne() {
        let state = CEFExtensionProfileState(current: [fixtureID: .init(folder: "same", fingerprint: "F")], known: [fixtureID])
        let plan = CEFExtensionFolderPlan.make(state: state, builds: [build("G")], installed: [fixtureID],
                                               foldersOnDisk: [fixtureID: ["same", "other"]], newName: { _ in "same" })
        XCTAssertTrue(plan.reuse.isEmpty)
        let name = try? XCTUnwrap(plan.prepare[fixtureID])
        XCTAssertNotNil(name)
        XCTAssertNotEqual(name, "same")
        XCTAssertNotEqual(name, "other")
    }

    func testMissingCurrentFolderIsPreparedAgainUnderANewName() {
        // The state names a folder that is gone (deleted by hand): never
        // reuse its name either.
        let state = CEFExtensionProfileState(current: [fixtureID: .init(folder: "gone", fingerprint: "F")], known: [fixtureID])
        let plan = CEFExtensionFolderPlan.make(state: state, builds: [build("F")], installed: [fixtureID],
                                               foldersOnDisk: [:], newName: { _ in "gone" })
        XCTAssertEqual(plan.prepare[fixtureID], "gone-1")
    }

    func testUnsafeNamesAreNeverUsed() {
        for unsafe in ["a,b", "_x", "..y", "", "a/b"] {
            let plan = CEFExtensionFolderPlan.make(state: .init(), builds: [build("F")], installed: [fixtureID],
                                                   foldersOnDisk: [fixtureID: ["copy"]], newName: { _ in unsafe })
            let name = plan.prepare[fixtureID] ?? ""
            XCTAssertFalse(name.isEmpty, unsafe)
            XCTAssertFalse(name.contains(","), unsafe)
            XCTAssertFalse(name.contains("/"), unsafe)
            XCTAssertFalse(name.hasPrefix("_") || name.hasPrefix("."), unsafe)
            XCTAssertNotEqual(name, "copy", unsafe)
        }
    }

    func testRemovedExtensionsLoseTheirDataDisabledOnesKeepIt() {
        let gone = "abcdefghijklmnopabcdefghijklmnop"
        let off = "ponmlkjihgfedcbaponmlkjihgfedcba"
        let state = CEFExtensionProfileState(current: [:], known: [gone, off, fixtureID])
        let plan = CEFExtensionFolderPlan.make(state: state, builds: [build("F")], installed: [off, fixtureID],
                                               foldersOnDisk: [:], newName: { _ in "n" })
        XCTAssertEqual(plan.deleteData, [gone])
    }

    func testNoListMeansNothingIsDeleted() {
        let state = CEFExtensionProfileState(current: [:], known: [fixtureID, "abcdefghijklmnopabcdefghijklmnop"])
        let plan = CEFExtensionFolderPlan.make(state: state, builds: [], installed: nil, foldersOnDisk: [:], newName: { _ in "n" })
        XCTAssertEqual(plan.deleteData, [])
    }

    func testPendingDeletionIsRetriedUntilDone() {
        let gone = "abcdefghijklmnopabcdefghijklmnop"
        let state = CEFExtensionProfileState(current: [:], known: [], pendingDeletion: [gone])
        let plan = CEFExtensionFolderPlan.make(state: state, builds: [], installed: [], foldersOnDisk: [:], newName: { _ in "n" })
        XCTAssertEqual(plan.deleteData, [gone])
    }

    // MARK: - Install list and state files

    private func temporaryFile(_ text: String?) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cef-list-\(UUID().uuidString).json")
        if let text { try? Data(text.utf8).write(to: url) }
        return url
    }

    func testInstallListAbsentUnreadableAndRead() {
        XCTAssertEqual(CEFExtensionInstallList.read(temporaryFile(nil)), .absent)
        if case .unreadable = CEFExtensionInstallList.read(temporaryFile("{\"extensions\": 5}")) {} else { XCTFail("not unreadable") }
        if case .unreadable = CEFExtensionInstallList.read(temporaryFile("")) {} else { XCTFail("empty file is not a list") }
        let ok = temporaryFile(#"{"extensions":[{"id":"\#(fixtureID)","source":"webStore","name":"H","version":"1.0","enabled":true,"pinned":false,"grants":[],"installedAt":"2026-11-15T00:00:00Z","declinedGrants":["perm:tabs"]}]}"#)
        guard case .list(let list, let declined) = CEFExtensionInstallList.read(ok) else { return XCTFail("not read") }
        XCTAssertEqual(list.extensions.map(\.id), [fixtureID])
        XCTAssertEqual(declined[fixtureID], ["perm:tabs"])
        XCTAssertEqual(CEFExtensionInstallList.read(temporaryFile(#"{"extensions":[]}"#)).list?.extensions.count, 0)
    }

    func testStateFileAbsentUnreadableAndRebuilt() {
        XCTAssertEqual(CEFExtensionProfileState.read(from: temporaryFile(nil)), .absent)
        XCTAssertEqual(CEFExtensionProfileState.read(from: temporaryFile("not json")), .unreadable)
        let rebuilt = CEFExtensionProfileState.rebuilt(foldersOnDisk: [fixtureID: ["a", "b"]],
                                                       workerFiles: [fixtureID: ["brw-background.v2-1.0-r3.js", "brw-background.v2-1.0-r7.js"]])
        XCTAssertEqual(rebuilt.known, [fixtureID])
        XCTAssertNil(rebuilt.lifecycle)
        XCTAssertEqual(rebuilt.revisions[fixtureID], 7)
        // A rebuilt state gives startup, never install.
        XCTAssertEqual(CEFExtensionLifecycle.due(record: rebuilt.lifecycle?[fixtureID], ranBefore: rebuilt.known.contains(fixtureID),
                                                 version: "1.0", session: "s"), [.startup])
    }

    // MARK: - Consent coverage

    func testChromiumGrantsMustBeCovered() throws {
        let grants = ["perm:storage", "perm:tabs", "host:<all_urls>"]
        var record = store(key: key)
        record.grants = ["perm:storage", "host:<all_urls>"]
        let facts = CEFExtensionSourceFacts(folder: "/p", folderExists: true, chromiumGrants: grants)
        XCTAssertEqual(CEFExtensionPlanner.decide(record, facts: facts), .needsApproval(grants))
        XCTAssertNotNil(CEFExtensionPlanner.decide(record, facts: facts, approved: ["perm:tabs"]).build)
        // A declined grant keeps it out, and no approval can change that.
        XCTAssertEqual(CEFExtensionPlanner.decide(record, facts: facts, approved: ["perm:tabs"], declined: ["perm:tabs"]),
                       .unavailable(CEFExtensionPlanner.declinedReason))
        // Access to every site covers one site.
        let oneSite = CEFExtensionSourceFacts(folder: "/p", folderExists: true, chromiumGrants: ["host:https://a.example/*"])
        XCTAssertNotNil(CEFExtensionPlanner.decide(record, facts: oneSite).build)
    }

    func testFoldersToDeleteKeepsOnlyTheKeptCopy() {
        let drop = CEFExtensionFolderPlan.foldersToDelete(onDisk: [fixtureID: ["a", "b"], "other": ["c"]], keep: [fixtureID: "b"])
        XCTAssertEqual(drop, [fixtureID: ["a"], "other": ["c"]])
    }

    func testRevisionOnlyGoesUpAndOnlyForUnpacked() {
        let unpackedBuild = build("unpacked|/dev/x|stamp|shim1|key")
        XCTAssertEqual(CEFExtensionFolderPlan.nextRevision(for: unpackedBuild, state: .init()), .use(1))
        let state = CEFExtensionProfileState(revisions: [fixtureID: 41])
        XCTAssertEqual(CEFExtensionFolderPlan.nextRevision(for: unpackedBuild, state: state), .use(42))
        XCTAssertEqual(CEFExtensionFolderPlan.nextRevision(for: build("store|1.0|shim1|key"), state: state), .none)
    }

    func testRevisionSurvivesALaunchWithNoCurrentCopy() {
        // Disabled or failed at one launch: no `current` entry, but the
        // revision stays, so the next copy never repeats one.
        let state = CEFExtensionProfileState(current: [:], known: [fixtureID], revisions: [fixtureID: 1])
        XCTAssertEqual(CEFExtensionFolderPlan.nextRevision(for: build("unpacked|/d|s|shim1|k"), state: state), .use(2))
    }

    func testRevisionAtTheCapIsRefusedNeverRepeated() {
        let unpackedBuild = build("unpacked|/d|s|shim1|k")
        XCTAssertEqual(CEFExtensionFolderPlan.nextRevision(for: unpackedBuild, state: .init(revisions: [fixtureID: 65534])), .use(65535))
        XCTAssertEqual(CEFExtensionFolderPlan.nextRevision(for: unpackedBuild, state: .init(revisions: [fixtureID: 65535])), .exhausted)
    }

    func testRevisionFromWorkerFileName() {
        XCTAssertEqual(CEFExtensionFolderPlan.revision(inWorkerFile: "brw-background.v2-2.0-r37.js"), 37)
        XCTAssertNil(CEFExtensionFolderPlan.revision(inWorkerFile: "brw-background.v2-2.0.js"))
        XCTAssertNil(CEFExtensionFolderPlan.revision(inWorkerFile: "brw-background.v2-2.0-rx.js"))
    }

    func testAllWebSitesDoesNotCoverFiles() {
        XCTAssertFalse(CEFExtensionPlanner.isCovered(["host:<all_urls>"], agreed: ["host:*://*/*"], declined: []))
        XCTAssertFalse(CEFExtensionPlanner.isCovered(["host:file:///*"], agreed: ["host:*://*/*"], declined: []))
        XCTAssertTrue(CEFExtensionPlanner.isCovered(["host:https://a.example/*"], agreed: ["host:*://*/*"], declined: []))
        XCTAssertTrue(CEFExtensionPlanner.isCovered(["host:file:///*", "host:*://*/*"], agreed: ["host:<all_urls>"], declined: []))
    }

    func testRevisionStopsWhereThePreparerCannotMakeAVersion() {
        let fourParts = CEFExtensionBuild(id: fixtureID, sourceFolder: "/s", publicKey: key, fingerprint: "unpacked|/d|s|shim3|k",
                                          sourceVersion: "1.2.3.65500")
        guard case .use(let first) = CEFExtensionFolderPlan.nextRevision(for: fourParts, state: .init()) else { return XCTFail("no revision") }
        XCTAssertNotNil(CEFExtensionShim.preparedVersion(storeVersion: "1.2.3.65500", shimVersion: CEFExtensionShim.version, revision: first))
        var revision = first
        while case .use(let next) = CEFExtensionFolderPlan.nextRevision(for: fourParts, state: .init(revisions: [fixtureID: revision])) {
            revision = next
            XCTAssertLessThan(revision, 65535)
        }
        XCTAssertNil(CEFExtensionShim.preparedVersion(storeVersion: "1.2.3.65500", shimVersion: CEFExtensionShim.version, revision: revision + 1))
    }

    func testApprovalsFile() throws {
        XCTAssertEqual(CEFExtensionApprovals.read(temporaryFile(nil)), .absent)
        XCTAssertEqual(CEFExtensionApprovals.read(temporaryFile("[1")), .unreadable)
        let url = temporaryFile(nil)
        try CEFExtensionApprovals.save([fixtureID: ["perm:tabs"]], to: url)
        XCTAssertEqual(CEFExtensionApprovals.read(url), .approvals([fixtureID: ["perm:tabs"]]))
    }

    func testWindowsCreateURLCapAndToken() {
        let many = (0..<26).map { "\"https://a.example/\($0)\"" }.joined(separator: ",")
        XCTAssertEqual(parse("windows.create", "{\"url\":[\(many)]}"), .failure(.malformed))
        XCTAssertEqual(CEFExtensionRequest.token(in: #"{"kind":"x","token":"abc","detail":{}}"#), "abc")
        XCTAssertNil(CEFExtensionRequest.token(in: #"{"kind":"x"}"#))
    }

    func testOldStateWithoutRevisionStillLoads() throws {
        let data = Data(#"{"current":{"x":{"folder":"f","fingerprint":"p"}},"known":["x"]}"#.utf8)
        let state = try JSONDecoder().decode(CEFExtensionProfileState.self, from: data)
        XCTAssertNil(state.current["x"]?.revision)
    }

    func testFolderName() {
        let name = CEFExtensionFolderPlan.folderName(version: "1.2/../3", shimVersion: 4, unique: "u")
        XCTAssertEqual(name, "v1.2-..-3-s4-u")
        XCTAssertFalse(name.contains("/"))
    }

    func testStateRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cef-state-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let state = CEFExtensionProfileState(current: [fixtureID: .init(folder: "f", fingerprint: "p")], known: [fixtureID])
        try state.save(to: url)
        XCTAssertEqual(CEFExtensionProfileState.load(from: url), state)
        XCTAssertEqual(CEFExtensionProfileState.load(from: url.appendingPathExtension("missing")), CEFExtensionProfileState())
    }

    func testDataPathsStayInsideTheProfile() {
        let paths = CEFExtensionData.profileRelativePaths(for: fixtureID)
        XCTAssertTrue(paths.contains("Local Extension Settings/\(fixtureID)"))
        XCTAssertTrue(paths.allSatisfy { !$0.hasPrefix("/") && !$0.contains("..") })
        XCTAssertEqual(CEFExtensionData.profileRelativePaths(for: "../../etc"), [])
    }

    // MARK: - Requests

    private func parse(_ kind: String, _ detail: String) -> Result<CEFExtensionRequest, CEFExtensionRequest.Refusal> {
        CEFExtensionRequest.parse(kind: kind, payloadJSON: #"{"kind":"\#(kind)","version":1,"detail":\#(detail)}"#, extensionId: fixtureID)
    }

    func testTabsCreate() {
        XCTAssertEqual(parse("tabs.create", #"{"url":"https://example.com/a","active":false,"pinned":true}"#),
                       .success(.openTab(url: URL(string: "https://example.com/a"), active: false, pinned: true)))
        XCTAssertEqual(parse("tabs.create", "{}"), .success(.openTab(url: nil, active: true, pinned: false)))
        XCTAssertEqual(parse("tabs.create", #"{"url":"chrome-extension://\#(fixtureID)/page.html"}"#),
                       .success(.openTab(url: URL(string: "chrome-extension://\(fixtureID)/page.html"), active: true, pinned: false)))
    }

    func testURLsOutsideTheRuleAreRefused() {
        for url in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,x", "chrome://settings",
                    "chrome-extension://abcdefghijklmnopabcdefghijklmnop/x.html", "about:blank", "http:///nohost"] {
            guard case .failure(let refusal) = parse("tabs.create", #"{"url":"\#(url)"}"#) else {
                return XCTFail("allowed \(url)")
            }
            XCTAssertNotEqual(refusal, .malformed, url)
        }
        XCTAssertEqual(parse("tabs.create", #"{"url":5}"#), .failure(.malformed))
    }

    func testWindowsCreate() {
        XCTAssertEqual(parse("windows.create", #"{"url":["https://a.example/","https://b.example/"],"focused":false}"#),
                       .success(.openWindow(urls: [URL(string: "https://a.example/")!, URL(string: "https://b.example/")!], focused: false)))
        XCTAssertEqual(parse("windows.create", #"{"url":["https://a.example/","file:///x"]}"#), .failure(.urlNotAllowed("file:///x")))
        XCTAssertEqual(parse("windows.create", #"{"url":[],"incognito":true}"#), .failure(.privateWindow))
    }

    func testClientsOpenWindowResolvesAgainstTheExtension() {
        XCTAssertEqual(parse("clients.openWindow", #"{"url":"welcome.html"}"#),
                       .success(.openClientWindow(url: URL(string: "chrome-extension://\(fixtureID)/welcome.html")!)))
        XCTAssertEqual(parse("clients.openWindow", "{}"), .failure(.malformed))
    }

    func testOtherKinds() {
        XCTAssertEqual(parse("runtime.openOptionsPage", #"{"url":"file:///ignored"}"#), .success(.openOptionsPage))
        XCTAssertEqual(parse("runtime.reload", "{}"), .success(.reload))
        XCTAssertEqual(parse("identity.launchWebAuthFlow", "{}"), .success(.webAuthFlow))
        XCTAssertEqual(parse("action.openPopup", #"{"windowId":7}"#), .success(.openPopup(windowId: 7)))
        XCTAssertEqual(parse("tabs.remove", "{}"), .failure(.unknownKind("tabs.remove")))
        XCTAssertEqual(CEFExtensionRequest.parse(kind: "tabs.create", payloadJSON: "[1]", extensionId: fixtureID), .failure(.malformed))
    }

    func testLifecycleKinds() {
        XCTAssertEqual(parse("worker.started", "{}"), .success(.workerStarted))
        XCTAssertEqual(parse("worker.activated", "{}"), .success(.workerActivated))
        XCTAssertEqual(parse("lifecycle.delivered", #"{"shimVersion":2,"delivered":[{"event":"onInstalled","reason":"install"},{"event":"onStartup"}]}"#),
                       .success(.lifecycleDelivered([.installed, .startup])))
        XCTAssertEqual(parse("lifecycle.delivered", #"{"delivered":[{"event":"onInstalled","reason":"update","previousVersion":"1.0"}]}"#),
                       .success(.lifecycleDelivered([.updated(previousVersion: "1.0")])))
        XCTAssertEqual(parse("lifecycle.delivered", "{}"), .failure(.malformed))
        XCTAssertEqual(parse("lifecycle.delivered", #"{"delivered":[{"event":"onInstalled","reason":"update"}]}"#), .failure(.malformed))
        XCTAssertEqual(parse("lifecycle.delivered", #"{"delivered":[{"event":"onSuspend"}]}"#), .failure(.malformed))
    }

    func testManifestPages() {
        let id = fixtureID
        XCTAssertEqual(CEFExtensionRequest.optionsPage(manifest: ["options_ui": ["page": "opts.html"]], extensionId: id),
                       URL(string: "chrome-extension://\(id)/opts.html"))
        XCTAssertEqual(CEFExtensionRequest.optionsPage(manifest: ["options_page": "o.html"], extensionId: id),
                       URL(string: "chrome-extension://\(id)/o.html"))
        XCTAssertNil(CEFExtensionRequest.optionsPage(manifest: ["options_page": "https://evil.example/"], extensionId: id))
        XCTAssertNil(CEFExtensionRequest.optionsPage(manifest: [:], extensionId: id))
        XCTAssertEqual(CEFExtensionRequest.popupPage(manifest: ["action": ["default_popup": "popup.html"]], extensionId: id),
                       URL(string: "chrome-extension://\(id)/popup.html"))
    }

    // MARK: - Tree stamp

    func testTreeStampChangesWithContentAndIgnoresMetadata() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cef-stamp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("_metadata"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: folder.appendingPathComponent("a.js"))
        let first = try XCTUnwrap(CEFExtensionTreeStamp.stamp(of: folder))
        try Data("x".utf8).write(to: folder.appendingPathComponent("_metadata/v.json"))
        XCTAssertEqual(CEFExtensionTreeStamp.stamp(of: folder), first)
        try Data("bb".utf8).write(to: folder.appendingPathComponent("a.js"))
        XCTAssertNotEqual(CEFExtensionTreeStamp.stamp(of: folder), first)
    }
}
