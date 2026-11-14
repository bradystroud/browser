import Foundation
import BrowserCore

/// Disk locations use BrowserCore's ProfilesRootResolver, matching the app.
/// Callers pass ParsedArgs.profilesRootArguments so values of unrelated flags
/// cannot accidentally become a profiles-root override. Metadata lives directly
/// in that directory; per-profile databases live under the profile's stable id.
/// Socket naming uses the metadata directory as a hash input, not a disk location.
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
