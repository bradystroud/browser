import Foundation

/// Isolates the rules WebKit refuses to compile out of a content rule list.
///
/// `WKContentRuleListStore` rejects a whole list over a single bad rule and
/// its error does not say which one. When a list fails, this compiles its two
/// halves separately, and keeps halving whatever still fails down to single
/// rules, so everything else still gets compiled and attached. Only the
/// planning lives here -- the compile itself is a callback -- which keeps it
/// testable without WebKit.
///
/// A list where nearly every rule is bad would otherwise cost about two
/// compiles per rule, so `maxAttempts` caps the work: once it is spent, a
/// range that still fails is rejected whole instead of split further.
public enum ContentRuleListBisector {
    public struct Result<Compiled> {
        /// One entry per range that compiled, in rule order.
        public var compiled: [(range: Range<Int>, list: Compiled)] = []
        /// Ranges left out: single bad rules, or larger ranges given up on
        /// once the attempt budget ran out.
        public var rejected: [Range<Int>] = []
        public var attempts = 0

        public var rejectedRuleCount: Int { rejected.reduce(0) { $0 + $1.count } }
    }

    public static let defaultMaxAttempts = 200

    /// Compiles rules `0..<ruleCount`, one range at a time, in order.
    /// `compile` must call its completion exactly once, with nil on failure;
    /// it may do so synchronously or later.
    public static func run<Compiled>(
        ruleCount: Int,
        maxAttempts: Int = defaultMaxAttempts,
        compile: @escaping (Range<Int>, @escaping (Compiled?) -> Void) -> Void,
        completion: @escaping (Result<Compiled>) -> Void
    ) {
        let state = State<Compiled>(pending: ruleCount > 0 ? [0..<ruleCount] : [])
        step(state, maxAttempts: maxAttempts, compile: compile, completion: completion)
    }

    private final class State<Compiled> {
        /// Last element is compiled next, so ranges are pushed right half first.
        var pending: [Range<Int>]
        var result = Result<Compiled>()
        init(pending: [Range<Int>]) { self.pending = pending }
    }

    private static func step<Compiled>(
        _ state: State<Compiled>,
        maxAttempts: Int,
        compile: @escaping (Range<Int>, @escaping (Compiled?) -> Void) -> Void,
        completion: @escaping (Result<Compiled>) -> Void
    ) {
        guard let range = state.pending.popLast() else {
            completion(state.result)
            return
        }
        state.result.attempts += 1
        compile(range) { list in
            if let list {
                state.result.compiled.append((range, list))
            } else if range.count == 1 || state.result.attempts >= maxAttempts {
                state.result.rejected.append(range)
            } else {
                let middle = range.lowerBound + range.count / 2
                state.pending.append(middle..<range.upperBound)
                state.pending.append(range.lowerBound..<middle)
            }
            step(state, maxAttempts: maxAttempts, compile: compile, completion: completion)
        }
    }

    /// The individual rules of a JSON rule list, each re-encoded as its own
    /// JSON object, or nil if `json` is not an array of objects.
    public static func rules(inList json: String) -> [String]? {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        var rules: [String] = []
        rules.reserveCapacity(array.count)
        for rule in array {
            guard let encoded = try? JSONSerialization.data(withJSONObject: rule, options: [.sortedKeys]),
                  let string = String(data: encoded, encoding: .utf8) else {
                return nil
            }
            rules.append(string)
        }
        return rules
    }

    /// A JSON rule list made of `rules`, as returned by `rules(inList:)`.
    public static func list<Rules: Collection>(fromRules rules: Rules) -> String where Rules.Element == String {
        "[" + rules.joined(separator: ",") + "]"
    }
}

/// `WKContentRuleListStore` identifiers for a profile's content-blocking
/// lists: `content-blocker.<profile>.<n>`, one per compiled list.
public enum ContentRuleListIdentifier {
    public static let prefix = "content-blocker."

    public static func make(profileName: String, index: Int) -> String {
        "\(prefix)\(profileName).\(index)"
    }

    /// Whether `identifier` is one of `profileName`'s lists, including the
    /// un-suffixed `content-blocker.<profile>` used before lists were chunked.
    /// Profile names may contain dots, so the un-suffixed form is only claimed
    /// when it cannot be another profile's numbered list: profile "a.1"'s old
    /// identifier is also profile "a"'s second list.
    public static func isIdentifier(_ identifier: String, ownedBy profileName: String) -> Bool {
        let base = prefix + profileName
        if identifier == base {
            return !hasNumericSuffix(profileName)
        }
        guard identifier.hasPrefix(base + ".") else { return false }
        return isNumber(identifier.dropFirst(base.count + 1))
    }

    private static func hasNumericSuffix(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: ".") else { return false }
        return isNumber(name[name.index(after: dot)...])
    }

    private static func isNumber(_ text: Substring) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
