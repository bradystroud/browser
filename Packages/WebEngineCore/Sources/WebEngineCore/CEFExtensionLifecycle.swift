import Foundation

/// Which `runtime.onInstalled` / `runtime.onStartup` events an extension in
/// CEF tabs is due, decided by the app because Chromium cannot: an extension
/// loaded from the `load-extension` switch sees `onInstalled` with reason
/// `install` at every launch and never `update`, and never `onStartup`. The
/// shim suppresses Chromium's own events and dispatches what the app says.
///
/// An event is offered at every worker start until the shim confirms it was
/// dispatched (`delivered`), and is never offered again after that, across
/// launches: the record lives in the profile's `state.json`.
public enum CEFExtensionLifecycle {
    /// What the app has confirmed for one extension in one profile.
    public struct Record: Codable, Equatable, Sendable {
        /// The store version whose `onInstalled` (install or update) was
        /// dispatched.
        public var installedVersion: String?
        /// The app session whose `onStartup` was dispatched, or which
        /// installed it (no `onStartup` then, as in Chrome).
        public var startupSession: String?

        public init(installedVersion: String? = nil, startupSession: String? = nil) {
            self.installedVersion = installedVersion
            self.startupSession = startupSession
        }
    }

    public enum Event: Equatable, Sendable {
        case installed
        case updated(previousVersion: String)
        case startup

        /// The event with the version or session it was decided for: a
        /// confirmation is matched against what is due now, so a late or
        /// unexpected one can never confirm a different event.
        public func token(version: String, session: String) -> String {
            switch self {
            case .installed: return "install@\(version)"
            case .updated(let previous): return "update@\(previous)>\(version)"
            case .startup: return "startup@\(session)"
            }
        }
    }

    /// The events due now.
    ///
    /// - Parameters:
    ///   - record: what was confirmed before, or nil.
    ///   - ranBefore: the extension ran in CEF tabs of this profile in an
    ///     earlier launch (the state file's `known` list as it was before this
    ///     launch). With no record, that means it was installed before the app
    ///     kept records: no `install`, only `onStartup`.
    ///   - version: the store version it runs now.
    ///   - session: this app launch's id.
    public static func due(record: Record?, ranBefore: Bool, version: String, session: String) -> [Event] {
        guard let record, let installed = record.installedVersion else {
            if ranBefore { return record?.startupSession == session ? [] : [.startup] }
            return [.installed]
        }
        var events: [Event] = []
        if installed != version { events.append(.updated(previousVersion: installed)) }
        if record.startupSession != session { events.append(.startup) }
        return events
    }

    /// The record after the shim confirmed `token`. An unknown or stale
    /// token changes nothing.
    public static func confirming(_ token: String, record: Record?, ranBefore: Bool, version: String, session: String) -> Record? {
        let pending = due(record: record, ranBefore: ranBefore, version: version, session: session)
        guard let event = pending.first(where: { $0.token(version: version, session: session) == token }) else { return record }
        var updated = record ?? Record(installedVersion: ranBefore ? version : nil)
        switch event {
        case .installed:
            updated.installedVersion = version
            // Chrome sends no onStartup in the session an extension was
            // installed in.
            updated.startupSession = session
        case .updated:
            updated.installedVersion = version
        case .startup:
            updated.startupSession = session
            if updated.installedVersion == nil { updated.installedVersion = version }
        }
        return updated
    }
}
