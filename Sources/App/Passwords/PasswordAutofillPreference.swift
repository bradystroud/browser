import Foundation

/// Whether a saved credential is filled into a matching login page
/// automatically, without waiting for a click on the omnibox key icon.
///
/// v1 of the password manager deliberately filled only on an explicit click,
/// on clickjacking grounds: a hostile page can position an invisible login
/// form and harvest whatever gets auto-filled into it. That reasoning is
/// real, and it is also the reasoning every mainstream browser has weighed
/// and come down the other way on -- Chrome and Firefox both fill
/// same-origin saved credentials on load. Requiring a click on a 26pt icon
/// that only appears once a presence message has arrived is, in practice,
/// indistinguishable from not remembering the password at all, which is
/// exactly the report this preference exists to answer.
///
/// So: on by default, matching Chrome, with a real off switch in Settings ->
/// Passwords for anyone who wants v1's behavior back. Filling is still
/// same-origin only (the Keychain lookup is keyed by the page's own host)
/// and still never happens on a page with no saved credential for that host.
///
/// Backed by AppPreferencesStore rather than UserDefaults.standard so an
/// agent's `--profiles-root` test launch can't change Brady's real setting
/// (browser-xrq -- see AppPreferencesStore's own doc comment).
enum PasswordAutofillPreference {
    private static let key = "PasswordAutofillAutomatic"

    static var isAutomaticFillEnabled: Bool {
        get {
            let defaults = AppPreferencesStore.current
            // `bool(forKey:)` returns false for an unset key, which is the
            // wrong default here -- check for the key's presence first so an
            // untouched preference means "on".
            guard defaults.object(forKey: key) != nil else { return true }
            return defaults.bool(forKey: key)
        }
        set {
            AppPreferencesStore.current.set(newValue, forKey: key)
        }
    }
}
