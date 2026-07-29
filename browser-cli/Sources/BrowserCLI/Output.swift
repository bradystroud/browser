import Foundation
import BrowserCLIProtocol

/// A plain string-message error for CLI-only failure paths (a missing
/// profile, an unresolvable bookmark folder, a missing required argument)
/// that don't need their own dedicated error type.
public struct SimpleError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Every command's own output path: `--json` prints exactly one line of
/// JSON to stdout (success or failure alike), so a script never has to
/// distinguish "parse stdout" from "parse stderr" depending on outcome;
/// plain-text mode prints a human-readable rendering to stdout on success,
/// or `Error: ...` to stderr on failure. `main()` uses the return value
/// (true = exit 0, false = exit 1) to set the process exit code.
public enum Output {
    @discardableResult
    public static func emit<T: Encodable>(_ value: T, json: Bool, text: (T) -> String) -> Bool {
        if json {
            printJSON(value)
        } else {
            print(text(value))
        }
        return true
    }

    @discardableResult
    public static func emitError(_ message: String, json: Bool) -> Bool {
        if json {
            printJSON(CLIResponse.failure(message))
        } else {
            FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
        }
        return false
    }

    private static func printJSON<T: Encodable>(_ value: T) {
        guard let data = try? JSONEncoder().encode(value), let string = String(data: data, encoding: .utf8) else {
            print("{\"ok\":false,\"error\":\"failed to encode output\"}")
            return
        }
        print(string)
    }
}
