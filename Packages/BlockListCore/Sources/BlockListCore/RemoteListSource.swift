import Foundation

/// Interface for a future remote block-list source (Phase 2) -- fetches an
/// updated list body, using an ETag for conditional requests so a refresh
/// that finds no change doesn't re-download or re-parse anything.
///
/// Genuinely unimplemented here -- there is no networking code in this
/// package. This type only pins down the shape Phase 2 needs to build
/// against (see the package README's "Remote list refresh" section).
public protocol RemoteListSource {
    /// Fetches the list if it has changed since `previousETag` (nil means
    /// "no cached version, always fetch"). Returns nil if the server
    /// reports no change (a real implementation: HTTP 304 Not Modified),
    /// in which case the caller should keep using its last-successfully-
    /// parsed list rather than clearing anything.
    func fetchIfUpdated(previousETag: String?) async throws -> RemoteListFetchResult?
}

/// A successfully fetched (changed) remote list body, plus the ETag to
/// remember for next time's conditional request.
public struct RemoteListFetchResult {
    public let text: String
    public let etag: String?

    public init(text: String, etag: String?) {
        self.text = text
        self.etag = etag
    }
}
