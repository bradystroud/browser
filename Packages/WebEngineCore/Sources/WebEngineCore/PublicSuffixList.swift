import Foundation

/// The Public Suffix List (publicsuffix.org), parsed from its own `.dat`
/// format, with both the ICANN and the private sections.
///
/// This is the real list, for decisions where a wrong answer is a security
/// hole -- which relying party a passkey request may name. `RegistrableDomain`
/// in BrowserCore is a heuristic for suggestion ordering only and must never
/// be used for that.
///
/// Rules are kept in their ASCII (punycode) form, because hosts arrive from
/// the engines already in that form (`xn--...`). The list itself writes
/// internationalized rules in Unicode, so they are converted on load.
public struct PublicSuffixList: Sendable {
    private let rules: Set<String>
    private let wildcards: Set<String>
    private let exceptions: Set<String>

    public init(datText: String) {
        var rules = Set<String>(), wildcards = Set<String>(), exceptions = Set<String>()
        for rawLine in datText.split(whereSeparator: \.isNewline) {
            // A rule ends at the first whitespace; anything after it is ignored.
            guard let token = rawLine.split(whereSeparator: \.isWhitespace).first,
                  !token.hasPrefix("//")
            else { continue }
            var rule = String(token)
            let isException = rule.hasPrefix("!")
            if isException { rule.removeFirst() }
            let isWildcard = rule.hasPrefix("*.")
            if isWildcard { rule.removeFirst(2) }
            guard let ascii = Self.asciiDomain(rule) else { continue }
            if isException {
                exceptions.insert(ascii)
            } else if isWildcard {
                wildcards.insert(ascii)
            } else {
                rules.insert(ascii)
            }
        }
        self.rules = rules
        self.wildcards = wildcards
        self.exceptions = exceptions
    }

    public var isEmpty: Bool { rules.isEmpty && wildcards.isEmpty && exceptions.isEmpty }

    /// The public suffix of `host`, by the list's own algorithm: the longest
    /// matching rule wins, an exception rule beats everything, and a host no
    /// rule covers falls under the implicit `*` rule (its last label).
    public func publicSuffix(of host: String) -> String? {
        guard let host = Self.asciiDomain(host) else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !labels.contains(where: \.isEmpty) else { return nil }
        for start in labels.indices {
            let candidate = labels[start...].joined(separator: ".")
            if exceptions.contains(candidate) {
                return labels[(start + 1)...].joined(separator: ".")
            }
            if rules.contains(candidate) {
                return candidate
            }
            if start + 1 < labels.count, wildcards.contains(labels[(start + 1)...].joined(separator: ".")) {
                return candidate
            }
        }
        return labels.last
    }

    public func isPublicSuffix(_ domain: String) -> Bool {
        guard let ascii = Self.asciiDomain(domain) else { return false }
        return publicSuffix(of: ascii) == ascii
    }

    /// Lowercased, without a trailing dot, with every non-ASCII label in its
    /// punycode form. Nil for an empty name or one that cannot be encoded.
    static func asciiDomain(_ name: String) -> String? {
        var name = name.lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty else { return nil }
        if name.allSatisfy(\.isASCII) { return name }
        var labels: [String] = []
        for label in name.split(separator: ".", omittingEmptySubsequences: false) {
            if label.allSatisfy(\.isASCII) {
                labels.append(String(label))
            } else {
                guard let encoded = Punycode.encode(String(label)) else { return nil }
                labels.append("xn--" + encoded)
            }
        }
        return labels.joined(separator: ".")
    }
}

/// RFC 3492 punycode encoding, for one label. Only encoding is needed:
/// the list is the only Unicode input.
enum Punycode {
    private static let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
    private static let initialBias = 72, initialN = 128

    static func encode(_ input: String) -> String? {
        let scalars = input.unicodeScalars.map { Int($0.value) }
        var output = scalars.filter { $0 < 0x80 }.map { Character(Unicode.Scalar(UInt8($0))) }
        let basicCount = output.count
        var handled = basicCount
        if basicCount > 0 { output.append("-") }
        var n = initialN, delta = 0, bias = initialBias
        while handled < scalars.count {
            guard let m = scalars.filter({ $0 >= n }).min() else { return nil }
            let (product, overflow) = (m - n).multipliedReportingOverflow(by: handled + 1)
            guard !overflow else { return nil }
            delta += product
            n = m
            for c in scalars {
                if c < n { delta += 1 }
                if c == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                        if q < t { break }
                        output.append(digit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(digit(q))
                    bias = adapt(delta: delta, count: handled + 1, first: handled == basicCount)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }
        return String(output)
    }

    private static func digit(_ d: Int) -> Character {
        Character(Unicode.Scalar(UInt8(d < 26 ? d + 97 : d + 22)))
    }

    private static func adapt(delta: Int, count: Int, first: Bool) -> Int {
        var delta = first ? delta / damp : delta / 2
        delta += delta / count
        var k = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }
        return k + (base - tMin + 1) * delta / (delta + skew)
    }
}
