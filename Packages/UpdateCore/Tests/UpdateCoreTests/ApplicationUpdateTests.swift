import XCTest
@testable import UpdateCore

final class ApplicationUpdateTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("update-core-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A fake Browser.app with only the Info.plist the checks read, plus a marker file.
    private func makeApp(at url: URL, version: String, marker: String) throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": ApplicationUpdate.bundleIdentifier,
                                   "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data(marker.utf8).write(to: contents.appendingPathComponent("marker"))
    }

    private func marker(_ app: URL) throws -> String {
        String(decoding: try Data(contentsOf: app.appendingPathComponent("Contents/marker")), as: UTF8.self)
    }

    private func makePlan(relaunch: Bool = true) throws -> ApplicationUpdatePlan {
        let target = root.appendingPathComponent("Browser.app")
        try makeApp(at: target, version: "0.1.4", marker: "old")
        let directory = root.appendingPathComponent(".browser-update-\(UUID().uuidString).noindex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let staged = directory.appendingPathComponent("Browser.app")
        try makeApp(at: staged, version: "0.1.5", marker: "new")
        var plan = ApplicationUpdatePlan(target: target, staged: staged, directory: directory, version: "0.1.5", sourceVersion: "0.1.4")
        plan.relaunch = relaunch
        try plan.save()
        return plan
    }

    func testPlanRoundTripsAndValidates() throws {
        let plan = try makePlan()
        XCTAssertEqual(try ApplicationUpdatePlan.load(plan.manifestURL), plan)
        XCTAssertNoThrow(try ApplicationUpdate.validatePlan(plan, manifest: plan.manifestURL))
    }

    /// `standardizedFileURL` drops a leading `/private`, so a plan saved under
    /// `/private/tmp` must still match the manifest path the helper is given.
    func testPlanUnderPrivateValidatesFromTheHelpersManifestPath() throws {
        guard root.path.hasPrefix("/var/") || root.path.hasPrefix("/tmp/") else { throw XCTSkip("no /private alias") }
        root = URL(fileURLWithPath: "/private" + root.path, isDirectory: true)
        let plan = try makePlan()
        let fromArguments = URL(fileURLWithPath: plan.manifestURL.path).standardizedFileURL
        XCTAssertNoThrow(try ApplicationUpdate.validatePlan(plan, manifest: fromArguments))
    }

    func testPlanOutsideAPrivateFolderIsRefused() throws {
        let plan = try makePlan()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: plan.directory.path)
        XCTAssertThrowsError(try ApplicationUpdate.validatePlan(plan, manifest: plan.manifestURL))
    }

    func testPlanWithAStagedAppElsewhereIsRefused() throws {
        let good = try makePlan()
        let bad = ApplicationUpdatePlan(target: good.target, staged: root.appendingPathComponent("Other.app"),
                                        directory: good.directory, version: "0.1.5", sourceVersion: "0.1.4")
        try bad.save()
        XCTAssertThrowsError(try ApplicationUpdate.validatePlan(bad, manifest: bad.manifestURL))
    }

    func testStageNames() {
        XCTAssertTrue(ApplicationUpdate.isStageName(".browser-update-\(UUID().uuidString).noindex"))
        XCTAssertFalse(ApplicationUpdate.isStageName(".browser-update-nope.noindex"))
        XCTAssertFalse(ApplicationUpdate.isStageName(".myterm-update-\(UUID().uuidString).noindex"))
    }

    func testApplySwapsAndKeepsThePreviousAppForRollback() throws {
        let plan = try makePlan()
        var launched: URL?
        try ApplicationUpdate.apply(plan, validateBundle: { _, _ in }, launch: { launched = $0 })
        XCTAssertEqual(try marker(plan.target), "new")
        XCTAssertEqual(try marker(plan.staged), "old")
        XCTAssertEqual(launched, plan.target)
        // The trial stays open until the new app confirms it.
        XCTAssertEqual(UpdateStartupTrial.pending(beside: plan.target, version: "0.1.5"), plan)
    }

    func testFailedStartupPutsThePreviousAppBack() throws {
        let plan = try makePlan()
        XCTAssertThrowsError(try ApplicationUpdate.apply(plan, validateBundle: { _, _ in }, launch: { _ in
            throw ApplicationUpdateError.startupFailed("no window")
        }))
        XCTAssertEqual(try marker(plan.target), "old")
        XCTAssertEqual(try marker(plan.staged), "new")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.directory.appendingPathComponent("superseded").path))
        XCTAssertNil(UpdateStartupTrial.pending(beside: plan.target, version: "0.1.5"))
    }

    func testInstallOnQuitDoesNotLaunch() throws {
        let plan = try makePlan(relaunch: false)
        try ApplicationUpdate.apply(plan, validateBundle: { _, _ in }, launch: { _ in XCTFail("must not launch") })
        XCTAssertEqual(try marker(plan.target), "new")
    }

    func testApplyRefusesWhenTheInstalledAppChanged() throws {
        let plan = try makePlan()
        try makeApp(at: plan.target, version: "0.1.6", marker: "other")
        XCTAssertThrowsError(try ApplicationUpdate.apply(plan, validateBundle: { _, _ in }, launch: { _ in }))
        XCTAssertEqual(try marker(plan.target), "other")
    }

    func testConfirmedTrialIsNoLongerPendingAndIsPruned() throws {
        let plan = try makePlan(relaunch: false)
        try ApplicationUpdate.apply(plan, validateBundle: { _, _ in }, launch: { _ in })
        // While unconfirmed, the folder holds the previous app and is kept.
        ApplicationUpdate.pruneCompletedUpdates(for: plan.target)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.directory.path))
        let pending = try XCTUnwrap(UpdateStartupTrial.pending(beside: plan.target, version: "0.1.5"))
        try UpdateStartupTrial.report(.loaded, plan: pending)
        XCTAssertEqual(UpdateStartupTrial.readReceipt(pending)?.phase, .loaded)
        try UpdateStartupTrial.commit(pending)
        XCTAssertNil(UpdateStartupTrial.pending(beside: plan.target, version: "0.1.5"))
        ApplicationUpdate.pruneCompletedUpdates(for: plan.target)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.directory.path))
    }

    func testInstallErrorIsReportedOnce() throws {
        let plan = try makePlan()
        try Data("could not".utf8).write(to: plan.directory.appendingPathComponent("install-error.txt"))
        XCTAssertEqual(ApplicationUpdate.takeInstallError(beside: plan.target), "could not")
        XCTAssertNil(ApplicationUpdate.takeInstallError(beside: plan.target))
    }

    func testDigest() throws {
        let file = root.appendingPathComponent("file")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try ApplicationUpdate.digest(file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testArm64Detection() throws {
        // A thin arm64 Mach-O header and a fat header holding arm64.
        let thin = root.appendingPathComponent("thin")
        try Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01] + [UInt8](repeating: 0, count: 24)).write(to: thin)
        XCTAssertTrue(try ApplicationUpdate.containsArm64(thin))
        let intel = root.appendingPathComponent("intel")
        try Data([0xcf, 0xfa, 0xed, 0xfe, 0x07, 0x00, 0x00, 0x01] + [UInt8](repeating: 0, count: 24)).write(to: intel)
        XCTAssertFalse(try ApplicationUpdate.containsArm64(intel))
        XCTAssertTrue(try ApplicationUpdate.containsArm64(URL(fileURLWithPath: "/bin/ls")))
    }

    func testRequirementPinsTheTeam() {
        XCTAssertTrue(ApplicationUpdate.requirement(identifier: "x").contains("subject.OU] = \"AQ6HPWB3D9\""))
        XCTAssertTrue(ApplicationUpdate.requirement(identifier: "x").hasSuffix("identifier \"x\""))
        XCTAssertFalse(ApplicationUpdate.requirement(identifier: nil).contains(" identifier \""))
    }
}
