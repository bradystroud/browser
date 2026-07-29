import Foundation

/// Where the app's CLI control socket lives -- one per running instance,
/// keyed by profiles-root, so a scratch (`--profiles-root <path>`) test
/// instance and Brady's real running instance never cross (browser-82d).
/// Shared by both the app (the listener, `Sources/App/CLI/CLIServer.swift`)
/// and the `browser` CLI (the client) so the naming convention lives in
/// exactly one place.
///
/// Deliberately *not* simply `<directory>/cli.sock`, despite `directory`
/// being the same one `profiles.json`/`session.json`/`routing.json` already
/// use (`ProfilesRootResolver.sessionAndProfilesMetadataDirectory`) --
/// `AF_UNIX`'s `sockaddr_un.sun_path` is hard-limited to 104 bytes on macOS
/// (confirmed directly: `MemoryLayout.size(ofValue: sockaddr_un().sun_path)
/// == 104`), and a real `--profiles-root` value can easily exceed that on
/// its own before `/cli.sock` is even appended -- an agent's own deeply
/// nested scratch-directory path did exactly this during testing,
/// overflowing the limit and silently disabling CLI control for that
/// instance. CEF hits this identical constraint for its own
/// `SingletonSocket` (visible alongside `profiles.json` in any profile
/// directory) and solves it the same way this does: a short, deterministic
/// name under the system temp directory instead of nested arbitrarily deep
/// under the profiles root. The hash is only ever used as a short, stable
/// *name* -- never reversed -- so two different `directory` values
/// collide only in the astronomically unlikely case of a 64-bit hash
/// collision, an acceptable risk for "how many Browser instances could a
/// single machine plausibly have running at once."
public enum CLISocketPath {
    public static func path(inDirectory directory: String) -> String {
        "/tmp/browser-cli-\(shortHash(directory)).sock"
    }

    /// FNV-1a 64-bit, rendered as hex -- deterministic (same `directory` ->
    /// same path, both processes agree without ever communicating it), no
    /// need for a cryptographic hash since this is a namespacing key, not a
    /// security boundary.
    private static func shortHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(hash, radix: 16)
    }
}
