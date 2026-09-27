import Foundation

/// Paste and Go / Paste and Search: what the clipboard's text becomes when
/// it is sent straight to the omnibox, and which of the two names the
/// command should wear for it.
public enum PasteAndGo {
    public enum Action: Equatable, Sendable {
        case go
        case search
    }

    /// The clipboard text as one omnibox line, or nil when there is nothing
    /// to use. Copied URLs often arrive wrapped across lines (from an email,
    /// a terminal, a PDF), so line breaks are first tried as if they were not
    /// there at all; only if that doesn't make a URL are the lines joined as
    /// words for a search.
    public static func normalize(_ text: String) -> String? {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        guard lines.count > 1 else { return lines[0] }
        let joined = lines.joined()
        if !joined.contains(where: \.isWhitespace), case .url = OmniboxInputClassifier.classify(joined) {
            return joined
        }
        return lines.joined(separator: " ")
    }

    public static func action(for text: String?) -> Action? {
        guard let text, let line = normalize(text) else { return nil }
        switch OmniboxInputClassifier.classify(line) {
        case .url: return .go
        case .search: return .search
        case .empty: return nil
        }
    }

    /// The menu title for the clipboard's current text. With nothing usable
    /// on the clipboard the item still needs a name while it is disabled.
    public static func menuTitle(for text: String?) -> String {
        action(for: text) == .search ? "Paste and Search" : "Paste and Go"
    }
}
