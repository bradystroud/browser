import Foundation

/// Where the app's CLI control socket lives -- one per running instance,
/// keyed by profiles-root, so a scratch (`--profiles-root <path>`) test
/// instance and Brady's real running instance never cross (browser-82d).
/// Shared by both the app (the listener, `Sources/App/CLI/CLIServer.swift`)
/// and the `browser` CLI (the client) so the filename convention lives in
/// exactly one place. Deliberately placed alongside `profiles.json`/
/// `session.json`/`routing.json` (see `ProfilesRootResolver.
/// sessionAndProfilesMetadataDirectory`) rather than under the per-profile
/// cache root, since it's process-wide, not per-profile, state -- exactly
/// the same directory those three files already use to fully redirect under
/// an explicit `--profiles-root` override.
public enum CLISocketPath {
    public static let fileName = "cli.sock"

    public static func path(inDirectory directory: String) -> String {
        (directory as NSString).appendingPathComponent(fileName)
    }
}
