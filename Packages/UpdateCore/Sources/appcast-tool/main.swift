import Foundation
import UpdateCore

// appcast-tool (browser-wc7) -- adds one release to the Sparkle appcast that
// GitHub Pages serves at https://bradystroud.github.io/browser/appcast.xml.
// Called from scripts/release.sh's appcast phase; run it by hand only to
// repair a feed.
//
// No argument-parsing dependency on purpose: this package is built by
// scripts/release.sh on Brady's machine mid-release, and a release pipeline
// that can fail on a package-registry fetch is a release pipeline that fails
// at the worst moment. Same reasoning the rest of Packages/ has no external
// dependencies either.

let usage = """
usage: appcast-tool add --appcast <path> --version <x.y.z> --url <download-url>
                        --length <bytes> --signature <sparkle:edSignature>
                        [--link <release-page-url>] [--title <text>]
                        [--pub-date <RFC822>] [--minimum-system-version <x.y.z>]

Adds (or replaces) the entry for --version in the appcast at --appcast,
re-sorts newest-first, and writes the file back. Creates the file if it does
not exist yet.

  --signature  the sparkle:edSignature value printed by Sparkle's sign_update
               tool for exactly the file at --url. Never a placeholder: an
               appcast entry whose signature does not verify is an update
               every installed copy will download and then reject.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n\n\(usage)\n".utf8))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail("no command given") }
guard command == "add" else { fail("unknown command '\(command)'") }
arguments.removeFirst()

var options: [String: String] = [:]
while !arguments.isEmpty {
    let flag = arguments.removeFirst()
    guard flag.hasPrefix("--") else { fail("unexpected argument '\(flag)'") }
    guard !arguments.isEmpty else { fail("'\(flag)' needs a value") }
    options[String(flag.dropFirst(2))] = arguments.removeFirst()
}

func required(_ name: String) -> String {
    guard let value = options[name], !value.isEmpty else { fail("--\(name) is required") }
    return value
}

let appcastPath = required("appcast")
let rawVersion = required("version")
guard let version = AppVersion(rawVersion) else {
    fail("--version '\(rawVersion)' is not a dotted numeric version")
}
let downloadURL = required("url")
let signature = required("signature")
guard let length = Int(required("length")), length > 0 else {
    fail("--length must be a positive byte count")
}

let releaseLink = options["link"] ?? "https://github.com/bradystroud/browser/releases/tag/v\(version)"
let newItem = AppcastItem(
    version: version,
    title: options["title"] ?? "Browser \(version)",
    link: releaseLink,
    pubDate: options["pub-date"] ?? AppcastDocument.rfc822(Date()),
    enclosureURL: downloadURL,
    enclosureLength: length,
    edSignature: signature,
    minimumSystemVersion: options["minimum-system-version"] ?? "12.0.0"
)

var existing: [AppcastItem] = []
if FileManager.default.fileExists(atPath: appcastPath) {
    guard let xml = try? String(contentsOfFile: appcastPath, encoding: .utf8) else {
        fail("could not read \(appcastPath)")
    }
    do {
        existing = try AppcastDocument.parseItems(xml: xml)
    } catch {
        // Refusing to overwrite is the right move: a feed that fails to
        // parse is either hand-edited or corrupt, and silently replacing it
        // with a single-entry file would drop every older release from the
        // feed for anyone still running one.
        fail("existing appcast at \(appcastPath) could not be parsed (\(error)); fix or remove it first")
    }
}

let merged = AppcastDocument.upsert(newItem, into: existing)
do {
    try AppcastDocument.render(items: merged).write(toFile: appcastPath, atomically: true, encoding: .utf8)
} catch {
    fail("could not write \(appcastPath): \(error.localizedDescription)")
}

print("Wrote \(appcastPath) -- \(merged.count) release(s), newest first:")
for item in merged {
    print("  \(item.version)  \(item.enclosureLength) bytes  \(item.enclosureURL)")
}
