import Foundation

/// A dotted numeric version, as used by `CFBundleVersion` and by an
/// appcast's `<sparkle:version>` -- the two values Sparkle compares to decide
/// whether an update exists.
///
/// This type does **not** re-implement that decision: at run time Sparkle's
/// own `SUStandardVersionComparator` makes it inside the app. What this is
/// for is the *publishing* side (`appcast-tool`, see this package's
/// executable target): ordering `<item>` elements newest-first and deciding
/// whether an entry being added replaces an existing one. Getting that
/// ordering wrong publishes a feed that offers users the wrong build, so it
/// is worth having tested rather than done with a shell `sort`.
public struct AppVersion: Equatable, Comparable, CustomStringConvertible {
    /// The numeric components, exactly as written. Not normalized: "0.2" and
    /// "0.2.0" compare equal (see `<`) but each renders back as it was
    /// given, so a version string round-trips through the appcast unchanged.
    public let components: [Int]

    private let original: String

    /// Parses a dotted numeric version. Any number of components is accepted
    /// (1 and 4 are both real in the wild -- "3" and "1.2.3.4"), a leading
    /// "v" is tolerated because git tags carry one, and anything else -- an
    /// empty string, a non-numeric or negative component, a trailing dot --
    /// is rejected rather than silently coerced to something orderable.
    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = trimmed
        if body.hasPrefix("v") || body.hasPrefix("V") {
            body = String(body.dropFirst())
        }
        guard !body.isEmpty else { return nil }

        var parsed: [Int] = []
        for piece in body.split(separator: ".", omittingEmptySubsequences: false) {
            guard !piece.isEmpty, piece.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(piece) else {
                return nil
            }
            parsed.append(value)
        }

        components = parsed
        // Deliberately `body`, not `trimmed`: a "v" accepted from a git tag
        // is dropped here rather than carried into the appcast, where
        // Sparkle would compare "v0.2.0" against the app's own bare
        // CFBundleVersion and find no match.
        original = body
    }

    /// Component-wise comparison, treating a missing trailing component as
    /// zero so "1.2" and "1.2.0" are the same version rather than the
    /// shorter one sorting first.
    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    /// The version as it was written, minus surrounding whitespace -- the
    /// form that goes back into the appcast.
    public var description: String { original }
}
