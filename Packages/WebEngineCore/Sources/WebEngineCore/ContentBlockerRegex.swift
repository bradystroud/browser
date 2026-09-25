import Foundation

/// WebKit's content-blocker `url-filter` accepts only a small subset of
/// regular-expression syntax (WebCore's URLFilterParser), and
/// `WKContentRuleListStore` rejects the *entire* list when a single rule's
/// filter falls outside it -- one bad rule means no blocking at all, with
/// only a `WKErrorDomain` error 6 ("Disjunctions are not supported yet" and
/// friends) to show for it. `validate(_:)` enforces that subset up front so
/// a rule that would sink the list is caught here instead:
///
/// - printable ASCII only;
/// - no `|` disjunction, no `{n,m}` counted quantifier;
/// - no backreference (`\1`) or built-in class escape (`\d`, `\w`, `\s`,
///   `\b`, ...), only escaped literals;
/// - no `(?...)` group of any kind (lookaround, non-capturing, named);
/// - `^` only as the first character, `$` only as the last;
/// - quantifiers `*`, `+`, `?` only directly after an atom, never stacked
///   (so no lazy `*?`);
/// - balanced, non-empty groups and bracket classes.
public enum ContentBlockerRegex {
    public enum ValidationError: Error, Equatable {
        case nonASCII
        case disjunction
        case countedQuantifier
        case backreference
        case builtinCharacterClass
        case unsupportedGroup
        case misplacedStartAnchor
        case misplacedEndAnchor
        case quantifierWithoutAtom
        case unbalancedParentheses
        case emptyGroup
        case unterminatedCharacterClass
        case trailingBackslash
        case empty
    }

    /// nil when `pattern` is inside WebKit's supported subset.
    public static func validate(_ pattern: String) -> ValidationError? {
        let chars = Array(pattern.unicodeScalars)
        guard !chars.isEmpty else { return .empty }
        if chars.contains(where: { !$0.isASCII || $0.value < 0x20 || $0.value == 0x7F }) {
            return .nonASCII
        }

        var depth = 0
        // Whether the previous token was something a quantifier can apply to.
        var canQuantify = false
        var index = 0
        while index < chars.count {
            let char = chars[index]
            switch char {
            case "\\":
                guard index + 1 < chars.count else { return .trailingBackslash }
                let escaped = chars[index + 1]
                if ("1"..."9").contains(escaped) { return .backreference }
                if "dDwWsSbBkpPcux0".unicodeScalars.contains(escaped) { return .builtinCharacterClass }
                index += 2
                canQuantify = true
                continue
            case "|":
                return .disjunction
            case "{":
                return .countedQuantifier
            case "^":
                if index != 0 { return .misplacedStartAnchor }
                canQuantify = false
            case "$":
                if index != chars.count - 1 { return .misplacedEndAnchor }
                canQuantify = false
            case "*", "+", "?":
                if !canQuantify { return .quantifierWithoutAtom }
                canQuantify = false
            case "(":
                if index + 1 < chars.count, chars[index + 1] == "?" { return .unsupportedGroup }
                if index + 1 < chars.count, chars[index + 1] == ")" { return .emptyGroup }
                depth += 1
                canQuantify = false
            case ")":
                depth -= 1
                if depth < 0 { return .unbalancedParentheses }
                canQuantify = true
            case "[":
                guard let end = endOfCharacterClass(chars, openingAt: index) else {
                    return .unterminatedCharacterClass
                }
                if let error = validateClassBody(chars[(index + 1)..<end]) { return error }
                index = end + 1
                canQuantify = true
                continue
            default:
                canQuantify = true
            }
            index += 1
        }
        return depth == 0 ? nil : .unbalancedParentheses
    }

    /// Expands `pattern`'s disjunctions into an equivalent list of
    /// disjunction-free patterns (`a(b|c)d` -> `abd`, `acd`), one WebKit rule
    /// each. Only unquantified groups can be expanded this way -- `(a|b)*`
    /// has no finite expansion -- and the result is capped at `limit`
    /// patterns so one pathological filter can't balloon the rule count.
    /// Returns nil when the pattern can't be expanded within those bounds;
    /// the caller drops that rule. A pattern with no disjunction comes back
    /// unchanged as a single element.
    public static func expandDisjunctions(_ pattern: String, limit: Int = 8) -> [String]? {
        let chars = Array(pattern.unicodeScalars)
        guard let alternatives = expand(chars, limit: limit) else { return nil }
        return alternatives.map { String(String.UnicodeScalarView($0)) }
    }

    // MARK: - Expansion

    private typealias Scalars = [Unicode.Scalar]

    /// Every alternative of the top-level sequence `chars`.
    private static func expand(_ chars: Scalars, limit: Int) -> [Scalars]? {
        var results: [Scalars] = []
        for branch in splitTopLevel(chars) {
            guard let expanded = expandSequence(branch, limit: limit) else { return nil }
            results += expanded
            if results.count > limit { return nil }
        }
        return results
    }

    /// Expands a sequence with no top-level `|`: literal runs are copied,
    /// and each unquantified group containing a disjunction is replaced by
    /// the cross product of its alternatives.
    private static func expandSequence(_ chars: Scalars, limit: Int) -> [Scalars]? {
        var partials: [Scalars] = [[]]
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "\\" {
                let end = min(index + 2, chars.count)
                partials = partials.map { $0 + chars[index..<end] }
                index = end
                continue
            }
            if char == "[" {
                let end = endOfCharacterClass(chars, openingAt: index) ?? (chars.count - 1)
                partials = partials.map { $0 + chars[index...end] }
                index = end + 1
                continue
            }
            if char == "(" {
                guard let close = matchingParen(chars, openingAt: index) else { return nil }
                let inner = Array(chars[(index + 1)..<close])
                let quantified = close + 1 < chars.count && "*+?{".unicodeScalars.contains(chars[close + 1])
                if containsDisjunction(inner) {
                    if quantified { return nil }
                    guard let innerAlternatives = expand(inner, limit: limit) else { return nil }
                    var next: [Scalars] = []
                    for partial in partials {
                        for alternative in innerAlternatives {
                            // Kept as a group so a quantifier-free group
                            // stays a group; `(abc)` and `abc` match alike.
                            next.append(partial + ["("] + alternative + [")"])
                            if next.count > limit { return nil }
                        }
                    }
                    partials = next
                } else {
                    partials = partials.map { $0 + chars[index...close] }
                }
                index = close + 1
                continue
            }
            partials = partials.map { $0 + [char] }
            index += 1
        }
        return partials
    }

    private static func containsDisjunction(_ chars: Scalars) -> Bool {
        var index = 0
        while index < chars.count {
            switch chars[index] {
            case "\\": index += 2; continue
            case "[": index = (endOfCharacterClass(chars, openingAt: index) ?? chars.count) + 1; continue
            case "|": return true
            default: index += 1
            }
        }
        return false
    }

    /// Splits on `|` at nesting depth zero (outside groups and classes).
    private static func splitTopLevel(_ chars: Scalars) -> [Scalars] {
        var branches: [Scalars] = []
        var current: Scalars = []
        var depth = 0
        var index = 0
        while index < chars.count {
            let char = chars[index]
            switch char {
            case "\\":
                current += chars[index..<min(index + 2, chars.count)]
                index += 2
                continue
            case "[":
                let end = endOfCharacterClass(chars, openingAt: index) ?? (chars.count - 1)
                current += chars[index...end]
                index = end + 1
                continue
            case "(":
                depth += 1
            case ")":
                depth -= 1
            case "|" where depth == 0:
                branches.append(current)
                current = []
                index += 1
                continue
            default:
                break
            }
            current.append(char)
            index += 1
        }
        branches.append(current)
        return branches
    }

    private static func matchingParen(_ chars: Scalars, openingAt start: Int) -> Int? {
        var depth = 0
        var index = start
        while index < chars.count {
            switch chars[index] {
            case "\\": index += 2; continue
            case "[":
                guard let end = endOfCharacterClass(chars, openingAt: index) else { return nil }
                index = end + 1
                continue
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
            index += 1
        }
        return nil
    }

    // MARK: - Character classes

    /// Index of the `]` closing the class that opens at `start`. A `]`
    /// immediately after `[` or `[^` is a literal, as in every regex dialect.
    private static func endOfCharacterClass(_ chars: Scalars, openingAt start: Int) -> Int? {
        var index = start + 1
        if index < chars.count, chars[index] == "^" { index += 1 }
        if index < chars.count, chars[index] == "]" { index += 1 }
        while index < chars.count {
            if chars[index] == "\\" { index += 2; continue }
            if chars[index] == "]" { return index }
            index += 1
        }
        return nil
    }

    private static func validateClassBody(_ body: ArraySlice<Unicode.Scalar>) -> ValidationError? {
        var index = body.startIndex
        if index < body.endIndex, body[index] == "^" { index += 1 }
        if index == body.endIndex { return .unterminatedCharacterClass }
        while index < body.endIndex {
            if body[index] == "\\" {
                guard index + 1 < body.endIndex else { return .trailingBackslash }
                if "dDwWsSbBkpPcux0123456789".unicodeScalars.contains(body[index + 1]) {
                    return .builtinCharacterClass
                }
                index += 2
                continue
            }
            index += 1
        }
        return nil
    }
}
