import Foundation

/// `browser --version` -- the version of the Browser.app this CLI is
/// inside, with the commit it was built from. The CLI is signed into
/// `Browser.app/Contents/Resources/bin/browser` and has no version of its
/// own, so a symlink on the PATH is followed back to that bundle.
enum VersionCommand {
    static func run(json: Bool) -> Bool {
        let executable = executableURL()
        let info = appInfo(near: executable)
        let version = info?["CFBundleShortVersionString"] as? String
        let commit = info?["BRWBuildCommit"] as? String
        let branch = info?["BRWBuildBranch"] as? String
        let dirty = info?["BRWBuildDirty"] as? Bool ?? false
        let app = info == nil ? nil : appPath(near: executable)

        if json {
            var object: [String: Any] = ["ok": true]
            object["version"] = version
            object["commit"] = commit
            object["branch"] = branch
            object["dirty"] = dirty
            object["app"] = app
            object["cli"] = executable.path
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            print(String(decoding: data, as: UTF8.self))
            return true
        }
        guard let version else {
            print("browser (version unknown: \(executable.path) is not inside a Browser.app)")
            return true
        }
        var line = "browser \(version)"
        if let commit { line += " (\(commit)\(dirty ? "-dirty" : "")\(branch.map { ", \($0)" } ?? ""))" }
        if let app { line += " \(app)" }
        print(line)
        return true
    }

    /// The real file this process runs from, through any symlink. argv[0]
    /// is only what the shell was given ("browser" for a PATH lookup), so it
    /// would resolve against the current folder; the kernel's exec path is
    /// the file found, and realpath follows every link from there.
    private static func executableURL() -> URL {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        let path = _NSGetExecutablePath(&buffer, &size) == 0 ? String(cString: buffer) : CommandLine.arguments[0]
        guard let real = realpath(path, nil) else { return URL(fileURLWithPath: path).resolvingSymlinksInPath() }
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real))
    }

    /// `<app>/Contents/Resources/bin/browser` -> `<app>`.
    private static func appPath(near executable: URL) -> String? {
        let app = executable.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app.path : nil
    }

    private static func appInfo(near executable: URL) -> [String: Any]? {
        guard let app = appPath(near: executable) else { return nil }
        let plist = URL(fileURLWithPath: app).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }
}
