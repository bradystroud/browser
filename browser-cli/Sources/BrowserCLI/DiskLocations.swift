import Foundation
import BrowserCore

/// Where the CLI reads/writes disk state, mirroring `CommandLineArgs.swift`
/// (`Sources/App`) exactly -- both resolve through `BrowserCore`'s real
/// `ProfilesRootResolver` (browser-1rp), so `--profiles-root <path>` means
/// the same thing to the CLI as it does to the app: profiles.json/
/// routing.json/session.json/cli.sock all live at
/// `sessionAndProfilesMetadataDirectory`, and each profile's `browser.db`
/// lives at `profilesRootPath/<profile.name>/browser.db`. Pass
/// `CommandLine.arguments` straight through -- `ProfilesRootResolver` only
/// ever looks for its own `--profiles-root <path>` pair and ignores
/// everything else, so there's no need to pre-filter.
public enum DiskLocations {
    public static func appSupportDirectory() -> String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path
    }

    public static func sessionAndProfilesMetadataDirectory(arguments: [String]) -> String {
        ProfilesRootResolver.sessionAndProfilesMetadataDirectory(arguments: arguments, appSupportDirectory: appSupportDirectory())
    }

    public static func profilesRootPath(arguments: [String]) -> String {
        ProfilesRootResolver.profilesRootPath(arguments: arguments, appSupportDirectory: appSupportDirectory())
    }
}
