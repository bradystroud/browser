import Foundation
import Testing
@testable import SearchCore

/// Helpers keep each case to one line, so the table of awkward inputs below
/// stays readable as a specification of the rules.
private func url(_ text: String) -> String? {
    if case .url(let resolved) = OmniboxInputClassifier.classify(text) { return resolved }
    return nil
}

private func search(_ text: String) -> String? {
    if case .search(let query) = OmniboxInputClassifier.classify(text) { return query }
    return nil
}

@Suite("Omnibox input: obvious URLs")
struct ObviousURLTests {
    @Test("an absolute http(s) URL passes through untouched")
    func absoluteURL() {
        #expect(url("https://example.com/a/b?c=d#e") == "https://example.com/a/b?c=d#e")
        #expect(url("http://example.com") == "http://example.com")
    }

    @Test("a bare hostname gains https://")
    func bareHostname() {
        #expect(url("example.com") == "https://example.com")
        #expect(url("www.example.com/path") == "https://www.example.com/path")
    }

    @Test("surrounding whitespace is trimmed before anything else")
    func trimsWhitespace() {
        #expect(url("  example.com  ") == "https://example.com")
        #expect(url("\nexample.com\n") == "https://example.com")
    }

    @Test("a trailing dot is a fully-qualified name, not an empty label")
    func fullyQualifiedName() {
        #expect(url("example.com.") == "https://example.com.")
    }

    @Test("an unknown scheme with an authority is still a URL -- app schemes exist")
    func unknownScheme() {
        #expect(url("zoommtg://zoom.us/join?confno=1") == "zoommtg://zoom.us/join?confno=1")
        #expect(url("slack://open") == "slack://open")
    }

    @Test("a URL keeps its scheme even when it contains a space")
    func schemeWinsOverSpace() {
        #expect(url("https://example.com/a b") == "https://example.com/a b")
    }
}

@Suite("Omnibox input: obvious searches")
struct ObviousSearchTests {
    @Test("anything containing a space is a search")
    func spaceMeansSearch() {
        #expect(search("hello world") == "hello world")
        #expect(search("what is swift") == "what is swift")
    }

    @Test("a single word with no dot is a search, not an intranet host")
    func singleWord() {
        #expect(search("swift") == "swift")
        #expect(search("github") == "github")
    }

    @Test("empty or whitespace-only input means nothing at all")
    func emptyInput() {
        #expect(OmniboxInputClassifier.classify("") == .empty)
        #expect(OmniboxInputClassifier.classify("   \n ") == .empty)
    }

    @Test("a leading ? forces a search however URL-like the rest looks")
    func forcedSearch() {
        #expect(search("?example.com") == "example.com")
        #expect(search("?https://example.com") == "https://example.com")
    }
}

@Suite("Omnibox input: text that merely contains dots")
struct DottedTextTests {
    @Test("a decimal number is a search, not a two-label host")
    func decimals() {
        #expect(search("3.14") == "3.14")
        #expect(search("1.2.3.4.5") == "1.2.3.4.5")
    }

    @Test("a doubled dot is not a hostname")
    func doubledDot() {
        #expect(search("wait..what") == "wait..what")
        #expect(search("hmm...") == "hmm...")
    }

    @Test("a one-character last label is not a TLD")
    func shortTLD() {
        #expect(search("foo.c") == "foo.c")
    }

    @Test("a leading dot is an empty label")
    func leadingDot() {
        #expect(search(".com") == ".com")
    }

    @Test("a real TLD wins even when the input reads like prose -- Chromium does the same")
    func realTLDNavigates() {
        #expect(url("node.js") == "https://node.js")
    }

    @Test("a dotted phrase with a space is still a search")
    func dottedPhraseWithSpace() {
        #expect(search("example.com is down") == "example.com is down")
    }
}

@Suite("Omnibox input: slashes")
struct SlashTests {
    @Test("a query containing a slash is a search when the first part is not a host")
    func slashQuery() {
        #expect(search("and/or") == "and/or")
        #expect(search("r/swift") == "r/swift")
        #expect(search("w/e") == "w/e")
    }

    @Test("a real host followed by a path is a URL")
    func hostWithPath() {
        #expect(url("github.com/apple/swift") == "https://github.com/apple/swift")
    }

    @Test("a path containing a space is a search")
    func pathWithSpace() {
        #expect(search("example.com/a b") == "example.com/a b")
    }

    @Test("a query string with no scheme still resolves")
    func queryStringNoScheme() {
        #expect(url("example.com?q=1") == "https://example.com?q=1")
    }
}

@Suite("Omnibox input: hosts, ports and IP literals")
struct HostPortTests {
    @Test("localhost is a host even without a dot, and defaults to http")
    func localhost() {
        #expect(url("localhost") == "http://localhost")
        #expect(url("localhost/api") == "http://localhost/api")
    }

    @Test("localhost:3000 is a host and a port, not a scheme")
    func localhostPort() {
        #expect(url("localhost:3000") == "http://localhost:3000")
        #expect(url("localhost:3000/api?x=1") == "http://localhost:3000/api?x=1")
    }

    @Test("a hostname with a port keeps http unless the port is 443")
    func hostWithPort() {
        #expect(url("example.com:8080") == "http://example.com:8080")
        #expect(url("example.com:443") == "https://example.com:443")
    }

    @Test("a colon followed by something that is not a port is a search")
    func nonNumericPort() {
        #expect(search("foo:bar") == "foo:bar")
        #expect(search("example.com:bar") == "example.com:bar")
    }

    @Test("a time of day is not a host and a port")
    func timeOfDay() {
        #expect(search("10:30") == "10:30")
        #expect(search("what happens at 2:30") == "what happens at 2:30")
    }

    @Test("an out-of-range port is a search")
    func portOutOfRange() {
        #expect(search("example.com:99999") == "example.com:99999")
        #expect(search("example.com:0") == "example.com:0")
    }

    @Test("an IPv4 literal is a host, over http")
    func ipv4() {
        #expect(url("192.168.1.1") == "http://192.168.1.1")
        #expect(url("192.168.1.1:8080/status") == "http://192.168.1.1:8080/status")
        #expect(url("127.0.0.1") == "http://127.0.0.1")
    }

    @Test("an out-of-range octet is not an IPv4 address")
    func ipv4OutOfRange() {
        #expect(search("999.1.1.1") == "999.1.1.1")
    }

    @Test("a bracketed IPv6 literal is a host")
    func ipv6() {
        #expect(url("[::1]") == "http://[::1]")
        #expect(url("[::1]:8080/x") == "http://[::1]:8080/x")
        #expect(url("http://[2001:db8::1]/") == "http://[2001:db8::1]/")
    }

    @Test("an unclosed or nonsense bracket is a search")
    func brokenIPv6() {
        #expect(search("[::1") == "[::1")
        #expect(search("[zz::1]") == "[zz::1]")
    }

    @Test("a Windows path is not a scheme")
    func windowsPath() {
        #expect(search("C:\\Users\\brady") == "C:\\Users\\brady")
    }
}

@Suite("Omnibox input: schemes with no authority")
struct OpaqueSchemeTests {
    @Test("about: and view-source: navigate")
    func aboutAndViewSource() {
        #expect(url("about:blank") == "about:blank")
        #expect(url("view-source:https://example.com") == "view-source:https://example.com")
        #expect(url("chrome://version") == "chrome://version")
    }

    @Test("mailto: and tel: navigate, so the system can hand them on")
    func externalSchemes() {
        #expect(url("mailto:someone@example.com") == "mailto:someone@example.com")
        #expect(url("tel:+61400000000") == "tel:+61400000000")
    }

    @Test("a scheme with nothing after it is a search")
    func emptyScheme() {
        #expect(search("mailto:") == "mailto:")
        #expect(search("https://") == "https://")
    }

    @Test("javascript: and data: are never navigated to, whoever typed them")
    func refusedSchemes() {
        #expect(search("javascript:alert(1)") == "javascript:alert(1)")
        #expect(search("data:text/html,<h1>hi</h1>") == "data:text/html,<h1>hi</h1>")
    }
}

@Suite("Omnibox input: unicode and IDN")
struct UnicodeTests {
    @Test("a unicode hostname resolves")
    func unicodeHost() {
        #expect(url("münchen.de") == "https://münchen.de")
        #expect(url("日本.jp/path") == "https://日本.jp/path")
    }

    @Test("a punycode hostname resolves")
    func punycode() {
        #expect(url("xn--bcher-kva.de") == "https://xn--bcher-kva.de")
    }

    @Test("a unicode TLD resolves")
    func unicodeTLD() {
        #expect(url("例え.みんな") == "https://例え.みんな")
    }

    @Test("unicode prose is a search")
    func unicodeProse() {
        #expect(search("こんにちは 世界") == "こんにちは 世界")
    }
}

@Suite("Omnibox input: things that look like credentials")
struct CredentialTests {
    @Test("an email address is a search, not a host with a user")
    func emailAddress() {
        #expect(search("someone@example.com") == "someone@example.com")
    }

    @Test("credentials in an explicit URL still work")
    func explicitCredentials() {
        #expect(url("https://user:pass@example.com/") == "https://user:pass@example.com/")
    }
}
