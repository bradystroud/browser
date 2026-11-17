import Foundation

/// A dotted numeric version, as stamped into `CFBundleShortVersionString`
/// and carried by a release tag (`v0.1.4`). The updater compares the running
/// app's version against the newest GitHub release with it.
public struct AppVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// The numeric components, exactly as written. Not normalized: "0.2" and
    /// "0.2.0" compare equal (see `<`) but each renders back as it was given.
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
        // is dropped, so a tag and the bundle's own version print the same.
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

    /// Hashes the zero-padded components, so two versions that compare equal
    /// ("1.2" and "1.2.0") also hash equal.
    public func hash(into hasher: inout Hasher) {
        var padded = components
        while let last = padded.last, last == 0 { padded.removeLast() }
        hasher.combine(padded)
    }

    /// The version as it was written, minus surrounding whitespace and any
    /// leading "v".
    public var description: String { original }
}
