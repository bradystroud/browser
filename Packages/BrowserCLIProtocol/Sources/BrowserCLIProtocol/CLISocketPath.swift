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
/// name under a temp directory instead of nested arbitrarily deep under the
/// profiles root.
///
/// That temp directory is the per-user one from
/// `confstr(_CS_DARWIN_USER_TEMP_DIR)` (`/var/folders/.../T/`), never the
/// shared `/tmp`: it is created mode 0700 for this user alone, so another
/// local account can neither connect to the socket nor pre-create a file at
/// its predictable name. Its length is fixed by the system (about 50
/// bytes), which keeps the full path well inside the 104-byte limit. The hash is only ever used as a short, stable
/// *name* -- never reversed -- so two different `directory` values
/// collide only in the astronomically unlikely case of a 64-bit hash
/// collision, an acceptable risk for "how many Browser instances could a
/// single machine plausibly have running at once."
public enum CLISocketPath {
    public static func path(inDirectory directory: String) -> String {
        path(inDirectory: directory, userTempDirectory: userTempDirectory())
    }

    static func path(inDirectory directory: String, userTempDirectory: String) -> String {
        let base = userTempDirectory.hasSuffix("/") ? userTempDirectory : userTempDirectory + "/"
        return "\(base)browser-cli-\(shortHash(directory)).sock"
    }

    /// The calling user's private temp directory. Both the app and the CLI
    /// run as the same user, so they always agree on it without
    /// communicating. `TMPDIR` is deliberately not consulted: it is an
    /// environment variable a caller can change, and the two processes
    /// must resolve the same path.
    static func userTempDirectory() -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard length > 0, length <= buffer.count else {
            // Should never happen for a real login user. The server still
            // restricts the socket to its own user (0600 plus a peer uid
            // check), so this only loses the directory-level protection.
            return "/tmp/"
        }
        return String(cString: buffer)
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
