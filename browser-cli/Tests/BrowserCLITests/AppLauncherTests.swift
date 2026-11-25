import XCTest
@testable import BrowserCLI

final class AppLauncherTests: XCTestCase {
    func testLaunchesOnlyForTheDiscoveredRealInstance() {
        XCTAssertTrue(AppLauncher.mayLaunch(args: ArgParser.parse(["open", "https://a.test", "--profile", "Work"]), environment: [:]))
        XCTAssertFalse(AppLauncher.mayLaunch(args: ArgParser.parse(["open", "https://a.test", "--no-launch"]), environment: [:]))
        XCTAssertFalse(AppLauncher.mayLaunch(args: ArgParser.parse(["focus", "--profiles-root", "/tmp/scratch"]), environment: [:]))
        XCTAssertFalse(AppLauncher.mayLaunch(args: ArgParser.parse(["focus", "--socket", "/tmp/a.sock"]), environment: [:]))
        XCTAssertFalse(AppLauncher.mayLaunch(args: ArgParser.parse(["focus"]), environment: ["BROWSER_CLI_SOCKET": "/tmp/a.sock"]))
    }

    func testNoLaunchIsAValuelessFlag() {
        let args = ArgParser.parse(["open", "--no-launch", "https://a.test"])
        XCTAssertEqual(args.positionals, ["open", "https://a.test"])
    }

    func testPrefersSystemApplicationsOverUserApplications() {
        XCTAssertEqual(AppLauncher.installedAppPath(fileExists: { _ in true }), "/Applications/Browser.app")
        XCTAssertEqual(AppLauncher.installedAppPath(fileExists: { $0.hasSuffix("/Applications/Browser.app") && $0 != "/Applications/Browser.app" }), "\(NSHomeDirectory())/Applications/Browser.app")
        XCTAssertNil(AppLauncher.installedAppPath(fileExists: { _ in false }))
    }
}
