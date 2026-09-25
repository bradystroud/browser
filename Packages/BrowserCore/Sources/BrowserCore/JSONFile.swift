import Foundation

/// One Codable value persisted as one JSON file -- the storage behind every
/// small settings or metadata file (profiles.json, routing.json,
/// session.json, and each profile's blocking.json, permissions.json and the
/// rest).
///
/// A file that exists but no longer decodes is moved aside to
/// `<name>.corrupt` before the default comes back. Returning the default
/// alone would let the caller's next save overwrite the only copy of the
/// user's data, with nothing to show it ever existed. A missing file is the
/// normal state for a profile that never changed the setting, so it stays
/// silent.
public struct JSONFile<Value: Codable> {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load(default defaultValue: @autoclosure () -> Value) -> Value {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if FileManager.default.fileExists(atPath: url.path) {
                NSLog("JSONFile: could not read %@, using defaults: %@", url.path, String(describing: error))
            }
            return defaultValue()
        }

        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            let corruptURL = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: corruptURL)
            do {
                try FileManager.default.moveItem(at: url, to: corruptURL)
                NSLog("JSONFile: %@ did not decode (%@), moved it to %@ and using defaults",
                      url.path, String(describing: error), corruptURL.lastPathComponent)
            } catch let moveError {
                NSLog("JSONFile: %@ did not decode (%@) and could not be moved aside: %@",
                      url.path, String(describing: error), String(describing: moveError))
            }
            return defaultValue()
        }
    }

    /// Failures are logged rather than thrown: no caller can do anything
    /// more useful with a full disk than keep running on its in-memory copy.
    public func save(_ value: Value) {
        do {
            let data = try JSONEncoder().encode(value)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("JSONFile: could not save %@: %@", url.path, String(describing: error))
        }
    }
}
