import Foundation

/// One row from a password-manager CSV export (browser-ymx's password
/// import). `password` is held here only as long as the caller needs it to
/// write into PasswordStore -- see PasswordImportCoordinator's own doc
/// comment (Sources/App) for the memory-lifetime and no-logging rules that
/// apply to every value in this struct once it leaves this parser.
public struct PasswordCSVEntry: Equatable {
    public let url: String
    public let username: String
    public let password: String
    public let title: String?
    public let note: String?
    public let otpAuthURL: String?

    public init(url: String, username: String, password: String, title: String? = nil, note: String? = nil, otpAuthURL: String? = nil) {
        self.url = url
        self.username = username
        self.password = password
        self.title = title
        self.note = note
        self.otpAuthURL = otpAuthURL
    }
}

/// Parses the CSV password-export format Chrome, Safari's Passwords app,
/// Firefox, Edge, 1Password, and Bitwarden all emit (browser-ymx) -- no
/// single standard, but they converge on the same shape: a header row of
/// column names (order and exact naming vary), then one credential per
/// data row. Handles what real exports actually contain: a UTF-8 BOM
/// (Safari's own export includes one), CRLF or bare LF line endings, and
/// RFC 4180-style quoted fields (a comma or newline inside a value, and a
/// literal `"` escaped as `""`).
///
/// SECURITY: this type has no logging anywhere in it, on purpose --
/// `password` values must never be written to a log, not even at debug
/// level, not even truncated. Keep it that way in any future change here.
public enum PasswordCSVParser {
    public enum ParseError: Error {
        case emptyFile
        /// The header row didn't contain recognizable url/username/password
        /// columns -- this file isn't a password export this parser
        /// understands, rather than silently returning zero entries.
        case unrecognizedColumns
    }

    /// Case-insensitive column-name aliases seen across real exports:
    /// Chrome's `name,url,username,password,note`, Safari's own
    /// `Title,URL,Username,Password,Notes,OTPAuth`, and the common
    /// 1Password/Bitwarden/Firefox variants (`login_uri`/`login_username`/
    /// `login_password`, `website`).
    private static let urlAliases: Set<String> = ["url", "login_uri", "website", "site"]
    private static let usernameAliases: Set<String> = ["username", "login_username", "user"]
    private static let passwordAliases: Set<String> = ["password", "login_password"]
    private static let titleAliases: Set<String> = ["name", "title"]
    private static let noteAliases: Set<String> = ["note", "notes"]
    private static let otpAliases: Set<String> = ["otpauth", "otp_auth_url", "otpauthurl", "otpauth url"]

    public static func parse(csv rawText: String) throws -> [PasswordCSVEntry] {
        var text = rawText
        if let bom = text.unicodeScalars.first, bom.value == 0xFEFF {
            text.unicodeScalars.removeFirst()
        }
        let rows = parseRows(text)
        guard let header = rows.first, !header.isEmpty else {
            throw ParseError.emptyFile
        }

        var urlIndex: Int?
        var usernameIndex: Int?
        var passwordIndex: Int?
        var titleIndex: Int?
        var noteIndex: Int?
        var otpIndex: Int?
        for (index, rawName) in header.enumerated() {
            let name = rawName.trimmingCharacters(in: .whitespaces).lowercased()
            if urlAliases.contains(name) { urlIndex = index }
            else if usernameAliases.contains(name) { usernameIndex = index }
            else if passwordAliases.contains(name) { passwordIndex = index }
            else if titleAliases.contains(name) { titleIndex = index }
            else if noteAliases.contains(name) { noteIndex = index }
            else if otpAliases.contains(name) { otpIndex = index }
        }
        guard let urlIndex, let usernameIndex, let passwordIndex else {
            throw ParseError.unrecognizedColumns
        }

        var entries: [PasswordCSVEntry] = []
        for row in rows.dropFirst() {
            // A short trailing row (e.g. a stray blank line at EOF) rather
            // than a malformed file -- skip it instead of failing the whole
            // import over one row.
            guard row.count > max(urlIndex, usernameIndex, passwordIndex) else { continue }
            let url = row[urlIndex]
            let username = row[usernameIndex]
            let password = row[passwordIndex]
            guard !url.isEmpty, !password.isEmpty else { continue }
            entries.append(PasswordCSVEntry(
                url: url,
                username: username,
                password: password,
                title: titleIndex.flatMap { row.indices.contains($0) ? nonEmpty(row[$0]) : nil },
                note: noteIndex.flatMap { row.indices.contains($0) ? nonEmpty(row[$0]) : nil },
                otpAuthURL: otpIndex.flatMap { row.indices.contains($0) ? nonEmpty(row[$0]) : nil }
            ))
        }
        return entries
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    /// A small RFC 4180-ish tokenizer: splits on commas and (CRLF or LF)
    /// newlines, except inside a `"`-quoted field, where both are literal
    /// content; `""` inside a quoted field is an escaped literal `"`.
    /// Deliberately hand-rolled rather than a naive `components(separatedBy:
    /// "\n")` split, which breaks the moment any field contains an embedded
    /// newline (a multi-line note is common in real password exports).
    private static func parseRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false

        // Unicode *scalars*, not Characters: Swift's Character is an
        // extended grapheme cluster, and "\r\n" is exactly one such
        // cluster -- iterating Character-by-character makes '\r' and '\n'
        // unobservable as separate values, so a CRLF-terminated file's
        // line breaks would silently fall through to "ordinary field
        // content" instead of ending the row (caught by this parser's own
        // CRLF test).
        let scalars = Array(text.unicodeScalars)
        var index = 0
        func endField() {
            currentRow.append(String(field))
            field = String.UnicodeScalarView()
        }
        func endRow() {
            endField()
            rows.append(currentRow)
            currentRow = []
        }

        while index < scalars.count {
            let scalar = scalars[index]
            if inQuotes {
                if scalar == "\"" {
                    if index + 1 < scalars.count, scalars[index + 1] == "\"" {
                        field.append("\"")
                        index += 2
                        continue
                    }
                    inQuotes = false
                    index += 1
                    continue
                }
                field.append(scalar)
                index += 1
                continue
            }

            switch scalar {
            case "\"":
                inQuotes = true
                index += 1
            case ",":
                endField()
                index += 1
            case "\r":
                // Bare CR (old Mac line endings) or the CR half of CRLF --
                // either way, the row ends here; a following "\n" is
                // consumed as part of the same line break below.
                endRow()
                index += 1
                if index < scalars.count, scalars[index] == "\n" { index += 1 }
            case "\n":
                endRow()
                index += 1
            default:
                field.append(scalar)
                index += 1
            }
        }
        // A final row with no trailing newline still needs to be flushed;
        // an empty `field`/`currentRow` at true EOF (a file that ends
        // cleanly with a newline) must NOT produce a bogus trailing empty
        // row, which is why this checks for any accumulated content first.
        if !field.isEmpty || !currentRow.isEmpty {
            endRow()
        }
        return rows
    }
}
