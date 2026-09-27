import Foundation

/// A Chromium-family browser whose data can be imported: where its user-data
/// directory lives under `~/Library/Application Support`, and the login
/// keychain item(s) it keeps its password-encryption passphrase in.
public struct ChromiumBrowser: Equatable, Hashable {
    public struct KeychainItem: Equatable, Hashable {
        public let service: String
        public let account: String

        public init(service: String, account: String) {
            self.service = service
            self.account = account
        }
    }

    public let name: String
    /// Relative to `~/Library/Application Support`.
    public let userDataFolder: String
    /// Tried in order; the first one present wins. More than one only where
    /// a browser's item name is not certain.
    public let keychainItems: [KeychainItem]

    public init(name: String, userDataFolder: String, keychainItems: [KeychainItem]) {
        self.name = name
        self.userDataFolder = userDataFolder
        self.keychainItems = keychainItems
    }

    private static func safeStorage(_ name: String) -> [KeychainItem] {
        [KeychainItem(service: "\(name) Safe Storage", account: name)]
    }

    /// Plain Chromium is deliberately absent: its keychain item
    /// ("Chromium Safe Storage" / "Chromium") is the very item this app's own
    /// CEF framework uses for its cookie key (see CLAUDE.md), so an import
    /// from it would read -- and prompt for -- this app's own secret.
    public static let known: [ChromiumBrowser] = [
        ChromiumBrowser(name: "Chrome", userDataFolder: "Google/Chrome", keychainItems: safeStorage("Chrome")),
        ChromiumBrowser(name: "Arc", userDataFolder: "Arc/User Data", keychainItems: safeStorage("Arc")),
        ChromiumBrowser(name: "Dia", userDataFolder: "Dia/User Data", keychainItems: safeStorage("Dia")),
        ChromiumBrowser(name: "Brave", userDataFolder: "BraveSoftware/Brave-Browser", keychainItems: safeStorage("Brave")),
        ChromiumBrowser(name: "Microsoft Edge", userDataFolder: "Microsoft Edge", keychainItems: safeStorage("Microsoft Edge")),
        ChromiumBrowser(name: "Vivaldi", userDataFolder: "Vivaldi", keychainItems: safeStorage("Vivaldi")),
        ChromiumBrowser(name: "Opera", userDataFolder: "com.operasoftware.Opera", keychainItems: safeStorage("Opera")),
        ChromiumBrowser(
            name: "Helium",
            userDataFolder: "net.imput.helium",
            keychainItems: [
                KeychainItem(service: "Helium Storage Key", account: "Helium"),
                KeychainItem(service: "Helium Safe Storage", account: "Helium"),
            ]
        ),
    ]
}

/// One profile inside a Chromium browser's user-data directory, e.g.
/// `Default` or `Profile 2`.
public struct ChromiumProfile: Equatable {
    public let browser: ChromiumBrowser
    /// The profile's folder name inside the user-data directory, which is
    /// also its key in `Local State`'s `profile.info_cache`.
    public let directoryName: String
    public let displayName: String
    public let directory: URL

    public init(browser: ChromiumBrowser, directoryName: String, displayName: String, directory: URL) {
        self.browser = browser
        self.directoryName = directoryName
        self.displayName = displayName
        self.directory = directory
    }

    public var loginDataURL: URL { directory.appendingPathComponent("Login Data") }
    public var bookmarksURL: URL { directory.appendingPathComponent("Bookmarks") }
    public var historyURL: URL { directory.appendingPathComponent("History") }

    public var hasLoginData: Bool { FileManager.default.fileExists(atPath: loginDataURL.path) }
    public var hasBookmarks: Bool { FileManager.default.fileExists(atPath: bookmarksURL.path) }
    public var hasHistory: Bool { FileManager.default.fileExists(atPath: historyURL.path) }
    public var hasAnything: Bool { hasLoginData || hasBookmarks || hasHistory }
}

/// Finds installed Chromium-family browsers and their profiles. Reads only
/// directory listings and the `Local State` JSON file -- never a profile's
/// databases, and never the keychain.
public enum ChromiumBrowserDiscovery {
    public static func defaultApplicationSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Every known browser that has at least one profile with something to
    /// import, each paired with those profiles.
    public static func installedBrowsers(
        in applicationSupport: URL = defaultApplicationSupportDirectory(),
        candidates: [ChromiumBrowser] = ChromiumBrowser.known
    ) -> [(browser: ChromiumBrowser, profiles: [ChromiumProfile])] {
        candidates.compactMap { browser in
            let profiles = self.profiles(of: browser, in: applicationSupport)
            return profiles.isEmpty ? nil : (browser, profiles)
        }
    }

    /// Profiles named in `Local State`'s `profile.info_cache` come first; any
    /// other profile
    /// folder holding browser data is appended so a stale or missing
    /// `Local State` never hides one. Opera keeps a single profile directly
    /// in the user-data folder, which is reported as one profile named after
    /// the browser.
    public static func profiles(of browser: ChromiumBrowser, in applicationSupport: URL) -> [ChromiumProfile] {
        let root = applicationSupport.appendingPathComponent(browser.userDataFolder, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        var profiles: [ChromiumProfile] = []
        var seen = Set<String>()

        for (directoryName, displayName) in namedProfiles(localStateURL: root.appendingPathComponent("Local State")) {
            let profile = ChromiumProfile(
                browser: browser,
                directoryName: directoryName,
                displayName: displayName,
                directory: root.appendingPathComponent(directoryName, isDirectory: true)
            )
            guard profile.hasAnything, seen.insert(directoryName).inserted else { continue }
            profiles.append(profile)
        }

        let folders = ((try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        )) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map(\.lastPathComponent)
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for directoryName in folders where !seen.contains(directoryName) {
            let profile = ChromiumProfile(
                browser: browser,
                directoryName: directoryName,
                displayName: directoryName,
                directory: root.appendingPathComponent(directoryName, isDirectory: true)
            )
            guard profile.hasAnything else { continue }
            seen.insert(directoryName)
            profiles.append(profile)
        }

        if profiles.isEmpty {
            let flat = ChromiumProfile(browser: browser, directoryName: "", displayName: browser.name, directory: root)
            if flat.hasAnything { profiles.append(flat) }
        }
        return profiles
    }

    /// `(directoryName, displayName)` pairs from `Local State`, `Default`
    /// first and then by folder name. Returns an empty array for a missing
    /// or malformed file.
    public static func namedProfiles(localStateURL: URL) -> [(String, String)] {
        guard let data = try? Data(contentsOf: localStateURL),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = top["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any]
        else { return [] }

        let entries: [(String, String)] = cache.compactMap { key, value in
            guard let info = value as? [String: Any] else { return nil }
            let name = (info["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? key
            return (key, name)
        }
        return entries.sorted { lhs, rhs in
            if lhs.0 == "Default" { return rhs.0 != "Default" }
            if rhs.0 == "Default" { return false }
            return lhs.0.localizedStandardCompare(rhs.0) == .orderedAscending
        }
    }
}
