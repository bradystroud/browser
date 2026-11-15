import Foundation

/// Edits to the JSON `Preferences` file Chromium keeps in each profile's
/// folder, made before the engine starts.
///
/// Chromium reads a pref once, when the profile loads, and rewrites the
/// whole file on its own schedule, so nothing here may run while a context
/// for the profile is open. Every edit merges into what is there: keys this
/// code does not know about are left as they are.
public enum ChromiumProfilePreferences {
    public static let fileName = "Preferences"

    /// A JSON value a pref can hold. Only what the edits below need.
    public enum Value: Equatable, Sendable {
        case bool(Bool)
        case int(Int)
        case string(String)
        case strings([String])

        var json: Any {
            switch self {
            case .bool(let value): return value
            case .int(let value): return value
            case .string(let value): return value
            case .strings(let value): return value
            }
        }
    }

    public struct Change: Equatable, Sendable {
        public enum Operation: Equatable, Sendable {
            case set(Value)
            /// Removes the key, and any parent that is left empty.
            case remove
            /// Makes `member` present in, or absent from, the list under the
            /// key, creating the list when it is needed and dropping it when
            /// the last member goes.
            case listMember(String, present: Bool)
        }

        /// Dotted pref names are written here as their parts, because a
        /// single name such as an extension id may itself hold a dot.
        public let path: [String]
        public let operation: Operation

        public init(path: [String], operation: Operation) {
            self.path = path
            self.operation = operation
        }
    }

    public enum Outcome: Equatable, Sendable {
        case created
        case updated
        /// The file already said what the changes say; it was not written.
        case unchanged
        /// The file exists and is not a JSON object. It was not touched.
        case leftAlone(reason: String)
    }

    public static func fileURL(inProfileFolder folder: URL) -> URL {
        folder.appendingPathComponent(fileName)
    }

    /// Applies `changes` in order to `<folder>/Preferences`. Creates the
    /// file, and the folder, when they are missing. Throws only for a file
    /// that cannot be read or written; a file that does not parse is
    /// reported, never overwritten.
    @discardableResult
    public static func apply(_ changes: [Change], toProfileFolder folder: URL) throws -> Outcome {
        let files = FileManager.default
        let url = fileURL(inProfileFolder: folder)
        var root: [String: Any] = [:]
        let existed = files.fileExists(atPath: url.path)
        if existed {
            let data = try Data(contentsOf: url)
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return .leftAlone(reason: "The Preferences file is not a JSON object.")
            }
            root = parsed
        }

        var edited = root
        for change in changes where !apply(change, to: &edited) {
            return .leftAlone(reason: "\(change.path.joined(separator: ".")) cannot be set: a parent in the Preferences file is not an object.")
        }
        if NSDictionary(dictionary: edited).isEqual(to: root) { return .unchanged }

        let data = try JSONSerialization.data(withJSONObject: edited, options: [.sortedKeys, .withoutEscapingSlashes])
        if !existed {
            try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try data.write(to: url, options: .atomic)
        return existed ? .updated : .created
    }

    // MARK: - Settings

    /// `extensions.extension_install_type_blocklist`: with `"command_line"`
    /// in it, Chromium loads nothing from `--load-extension` into the
    /// profile. A profile that runs no CEF extension gets it; one that runs
    /// any has it removed.
    public static func commandLineExtensionsBlocked(_ blocked: Bool) -> Change {
        Change(
            path: ["extensions", "extension_install_type_blocklist"],
            operation: .listMember("command_line", present: blocked)
        )
    }

    // MARK: - Pieces

    /// False when a parent on the way is not an object, and nothing was changed.
    static func apply(_ change: Change, to root: inout [String: Any]) -> Bool {
        guard !change.path.isEmpty else { return true }
        switch change.operation {
        case .set(let value):
            return write(change.path[...], in: &root) { $0 = value.json }
        case .remove:
            return write(change.path[...], in: &root) { $0 = nil }
        case .listMember(let member, let present):
            return write(change.path[...], in: &root) { current in
                var members = (current as? [Any])?.compactMap { $0 as? String } ?? []
                if present {
                    if !members.contains(member) { members.append(member) }
                } else {
                    members.removeAll { $0 == member }
                }
                current = members.isEmpty ? nil : members
            }
        }
    }

    /// Runs `edit` on the value at `path`, making the dictionaries on the way
    /// when the edit leaves a value, and dropping any that it leaves empty.
    private static func write(_ path: ArraySlice<String>, in dictionary: inout [String: Any], edit: (inout Any?) -> Void) -> Bool {
        guard let key = path.first else { return true }
        if path.count == 1 {
            var value = dictionary[key]
            edit(&value)
            dictionary[key] = value
            return true
        }
        let existing = dictionary[key]
        // A parent that is not an object is something this code did not write.
        guard existing == nil || existing is [String: Any] else { return false }
        var child = existing as? [String: Any] ?? [:]
        let wasEmpty = child.isEmpty
        guard write(path.dropFirst(), in: &child, edit: edit) else { return false }
        if !child.isEmpty {
            dictionary[key] = child
        } else if !wasEmpty {
            dictionary[key] = nil
        }
        return true
    }
}
