import Foundation

/// A lightweight stand-in for the app's own `Profile` (`Sources/App/
/// Profile.swift`) -- that type lives in the Xcode/CMake app target, not a
/// package this CLI can depend on, but it's a plain 3-field `Codable`
/// struct, so decoding `profiles.json` into this shape works identically.
/// Never gains a fourth field for anything credential-shaped -- profiles.json
/// itself never holds any (see ProfileManager.swift), and this type
/// shouldn't be the first place that changes.
public struct ProfileRecord: Codable, Equatable {
    public let id: String
    public let name: String
    public let colorHex: String

    public init(id: String, name: String, colorHex: String) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
    }
}

public enum ProfileRecordStore {
    /// Reads `<directory>/profiles.json`, the same file `ProfileManager`
    /// persists (`Sources/App/ProfileManager.swift`). Returns an empty array
    /// (not an error) if the file doesn't exist yet -- a brand-new
    /// `--profiles-root` scratch directory the app hasn't launched into yet
    /// is a legitimate, expected state for the CLI to encounter, not a
    /// failure.
    public static func load(directory: String) -> [ProfileRecord] {
        let path = (directory as NSString).appendingPathComponent("profiles.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let decoded = try? JSONDecoder().decode([ProfileRecord].self, from: data) else {
            return []
        }
        return decoded
    }
}
