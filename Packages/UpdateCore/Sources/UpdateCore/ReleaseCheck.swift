import Foundation

/// One published GitHub release, and the verified download the updater may install.
public struct AppRelease: Equatable, Sendable {
    public struct Asset: Equatable, Sendable {
        public let url: URL
        public let sha256: String
        public init(url: URL, sha256: String) { self.url = url; self.sha256 = sha256 }
    }

    public let version: AppVersion
    public let tag: String
    public let releaseURL: URL
    public let name: String?
    /// `nil` while GitHub has not published the DMG's digest. The release is
    /// still offered, but only its page can be opened.
    public let asset: Asset?

    public init(version: AppVersion, tag: String, releaseURL: URL, name: String? = nil, asset: Asset? = nil) {
        self.version = version
        self.tag = tag
        self.releaseURL = releaseURL
        self.name = name
        self.asset = asset
    }
}

public enum UpdateAvailability: Equatable, Sendable {
    case upToDate(current: AppVersion)
    case available(AppRelease)

    public var release: AppRelease? {
        guard case .available(let release) = self else { return nil }
        return release
    }
}

public enum UpdateCheckError: Error, Equatable, LocalizedError, Sendable {
    case unreadableCurrentVersion(String)
    case unreadableResponse(reason: String)
    case noPublishedRelease

    public var errorDescription: String? {
        switch self {
        case .unreadableCurrentVersion(let raw): "This build reports an unreadable version (\(raw))."
        case .unreadableResponse(let reason): "Could not read the release information: \(reason)"
        case .noPublishedRelease: "There is no published release to compare against."
        }
    }
}

/// Compares the running version with the newest GitHub release. The network
/// stays with the caller, so this part is testable.
public enum ReleaseCheck {
    public static let repository = "bradystroud/browser"

    /// GitHub's `releases/latest` already excludes drafts and prereleases.
    public static let latestReleaseEndpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    /// The release's own download name. `Browser.dmg`, the stable-named copy
    /// for the website, is the same bytes but is not used: a versioned name
    /// cannot be confused with another release's file.
    public static func assetName(for version: AppVersion) -> String { "Browser-\(version).dmg" }

    public static func availability(currentVersion: String, latestReleaseJSON data: Data) throws -> UpdateAvailability {
        guard let current = AppVersion(currentVersion) else {
            throw UpdateCheckError.unreadableCurrentVersion(currentVersion)
        }
        let release = try parseRelease(data)
        return release.version > current ? .available(release) : .upToDate(current: current)
    }

    /// Reads one release and keeps GitHub's own API error message for the settings UI.
    public static func parseRelease(_ data: Data) throws -> AppRelease {
        let payload: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw UpdateCheckError.unreadableResponse(reason: "the response was not an object")
            }
            payload = object
        } catch let error as UpdateCheckError {
            throw error
        } catch {
            throw UpdateCheckError.unreadableResponse(reason: error.localizedDescription)
        }

        if payload["tag_name"] == nil, let message = payload["message"] as? String {
            // A repository with no releases answers 404 with a message body rather than a release.
            throw message.localizedCaseInsensitiveContains("not found")
                ? UpdateCheckError.noPublishedRelease
                : UpdateCheckError.unreadableResponse(reason: message)
        }
        guard let tag = payload["tag_name"] as? String else {
            throw UpdateCheckError.unreadableResponse(reason: "the response had no tag_name")
        }
        guard let version = AppVersion(tag) else {
            throw UpdateCheckError.unreadableResponse(reason: "could not read a version from tag \(tag)")
        }
        guard let address = payload["html_url"] as? String, let url = URL(string: address),
              url.scheme == "https", url.host == "github.com" else {
            throw UpdateCheckError.unreadableResponse(reason: "the response had no usable html_url")
        }
        let name = (payload["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let fileName = assetName(for: version)
        // The exact URL is required, so a release that lists some other host's
        // file under the expected name is never downloaded.
        let expectedURL = "https://github.com/\(repository)/releases/download/\(tag)/\(fileName)"
        let asset = (payload["assets"] as? [[String: Any]])?.compactMap { value -> AppRelease.Asset? in
            guard value["name"] as? String == fileName,
                  let address = value["browser_download_url"] as? String, address == expectedURL,
                  let downloadURL = URL(string: address),
                  let digest = value["digest"] as? String, digest.hasPrefix("sha256:") else { return nil }
            let hash = String(digest.dropFirst(7))
            guard isSHA256(hash) else { return nil }
            return AppRelease.Asset(url: downloadURL, sha256: hash)
        }.first
        return AppRelease(version: version, tag: tag, releaseURL: url, name: name, asset: asset)
    }

    public static func isSHA256(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { "0123456789abcdef".contains($0) }
    }
}
