import Foundation

/// What to ask after a sign-in, given what the browser's own store already
/// holds for that site and user name.
///
/// When the browser does not offer to save (the user turned it off, or a
/// password-manager extension holds `passwordSavingEnabled` at false and
/// asks its own question), a new password is left to that extension. A
/// password the browser already holds under the same user name is still
/// offered for update: otherwise the browser would go on filling the old
/// one on every visit, with nothing ever correcting it.
public enum PasswordSavePrompt: Equatable {
    case none
    case save
    case update

    /// `savedPassword` is the browser's own password for exactly this site
    /// and `username`, if it has one.
    public static func decide(offersSaving: Bool, password: String, savedPassword: String?) -> PasswordSavePrompt {
        guard !password.isEmpty else { return .none }
        if let savedPassword {
            return savedPassword == password ? .none : .update
        }
        return offersSaving ? .save : .none
    }
}
