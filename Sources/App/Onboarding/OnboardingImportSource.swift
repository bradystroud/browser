import AppKit
import UniformTypeIdentifiers

/// One row on the onboarding window's import page: a profile of another
/// browser on this Mac, or a file the user chose.
struct OnboardingImportSource {
    enum Kind {
        case safari(SafariImportProfile)
        case chromium(ChromiumProfile)
        case bookmarksFile(URL, [ImportedBookmarkNode])
        /// SECURITY: plaintext passwords. The onboarding window drops the
        /// row as soon as it is imported, and every row when it closes.
        case passwordsFile(URL, [PasswordCSVEntry])
    }

    let kind: Kind
    let title: String
    let detail: String
    let icon: NSImage
    /// What a new profile is called when this row is imported into one.
    let newProfileName: String
    /// From the browser that is the system default right now, so the row
    /// starts checked.
    let isFromDefaultBrowser: Bool

    var isFile: Bool {
        switch kind {
        case .bookmarksFile, .passwordsFile: return true
        case .safari, .chromium: return false
        }
    }
}

enum OnboardingSourceDiscovery {
    static let safariBundleId = "com.apple.Safari"

    /// Only for each browser's icon and for matching the default browser;
    /// `ChromiumBrowser` itself knows nothing of app bundles.
    private static let chromiumBundleIds: [String: String] = [
        "Chrome": "com.google.Chrome",
        "Arc": "company.thebrowser.Browser",
        "Dia": "company.thebrowser.dia",
        "Brave": "com.brave.Browser",
        "Microsoft Edge": "com.microsoft.edgemac",
        "Vivaldi": "com.vivaldi.Vivaldi",
        "Opera": "com.operasoftware.Opera",
        "Helium": "net.imput.helium",
    ]

    static func defaultBrowserBundleId() -> String? {
        guard let url = URL(string: "https://example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return Bundle(url: app)?.bundleIdentifier
    }

    static var isThisAppDefaultBrowser: Bool {
        defaultBrowserBundleId() == Bundle.main.bundleIdentifier
    }

    static var isSafariInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: safariBundleId) != nil
    }

    static func appIcon(bundleId: String?) -> NSImage {
        if let bundleId, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage()
    }

    static func safariSources(from result: SafariImportScanner.Result, defaultBundleId: String?) -> [OnboardingImportSource] {
        let icon = appIcon(bundleId: safariBundleId)
        let isDefault = defaultBundleId == safariBundleId
        let single = result.profiles.count == 1
        return result.profiles
            .filter { $0.bookmarkCount + $0.favoriteCount + $0.historyCount > 0 }
            .map { profile in
                let name = profile.id == SafariImportScanner.defaultProfileId ? "Default" : profile.displayName
                let title = single ? "Safari" : "Safari \u{2013} \(name)"
                var parts: [String] = []
                if profile.bookmarkCount > 0 { parts.append(count(profile.bookmarkCount, "bookmark")) }
                if profile.favoriteCount > 0 { parts.append(count(profile.favoriteCount, "favourite")) }
                if profile.historyCount > 0 { parts.append(count(profile.historyCount, "history item")) }
                return OnboardingImportSource(
                    kind: .safari(profile),
                    title: title,
                    detail: parts.joined(separator: " \u{00B7} "),
                    icon: icon,
                    newProfileName: title,
                    isFromDefaultBrowser: isDefault
                )
            }
    }

    static func chromiumSources(defaultBundleId: String?) -> [OnboardingImportSource] {
        ChromiumBrowserDiscovery.installedBrowsers().flatMap { entry -> [OnboardingImportSource] in
            let bundleId = chromiumBundleIds[entry.browser.name]
            let icon = appIcon(bundleId: bundleId)
            let isDefault = bundleId != nil && bundleId == defaultBundleId
            let single = entry.profiles.count == 1
            return entry.profiles.map { profile in
                let title = single ? entry.browser.name : "\(entry.browser.name) \u{2013} \(profile.displayName)"
                var kinds: [String] = []
                if profile.hasBookmarks { kinds.append("bookmarks") }
                if profile.hasHistory { kinds.append("history") }
                if profile.hasLoginData { kinds.append("passwords") }
                return OnboardingImportSource(
                    kind: .chromium(profile),
                    title: title,
                    detail: sentence(kinds),
                    icon: icon,
                    newProfileName: title,
                    isFromDefaultBrowser: isDefault
                )
            }
        }
    }

    static func bookmarksFileSource(url: URL, nodes: [ImportedBookmarkNode]) -> OnboardingImportSource {
        let counts = ImportedBookmarkNode.counts(in: nodes)
        return OnboardingImportSource(
            kind: .bookmarksFile(url, nodes),
            title: url.lastPathComponent,
            detail: count(counts.bookmarks, "bookmark") + " in " + count(counts.folders, "folder"),
            icon: NSWorkspace.shared.icon(for: .html),
            newProfileName: "Imported Bookmarks",
            isFromDefaultBrowser: false
        )
    }

    static func passwordsFileSource(url: URL, entries: [PasswordCSVEntry]) -> OnboardingImportSource {
        OnboardingImportSource(
            kind: .passwordsFile(url, entries),
            title: url.lastPathComponent,
            detail: count(entries.count, "password"),
            icon: NSWorkspace.shared.icon(for: .commaSeparatedText),
            newProfileName: "Imported Passwords",
            isFromDefaultBrowser: false
        )
    }

    static func count(_ n: Int, _ noun: String) -> String {
        let number = NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
        return "\(number) \(noun)\(n == 1 ? "" : "s")"
    }

    /// ["bookmarks", "history", "passwords"] -> "Bookmarks, history and passwords"
    private static func sentence(_ words: [String]) -> String {
        let joined: String
        switch words.count {
        case 0: return ""
        case 1: joined = words[0]
        default: joined = words.dropLast().joined(separator: ", ") + " and " + words[words.count - 1]
        }
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }
}
