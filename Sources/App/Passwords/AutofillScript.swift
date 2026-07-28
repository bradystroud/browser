import Foundation

/// Builds the one-shot script executed when the user clicks the omnibox key
/// icon (browser-ojh.1) -- never run automatically on page load; only ever
/// in direct response to that explicit click (see PasswordManagerCoordinator's
/// key-icon handling), since silently filling credentials into a page
/// without a user gesture is a clickjacking/leak risk (a malicious page
/// could position an invisible form to harvest an auto-filled credential
/// without the user ever intending to submit it there).
enum AutofillScript {
    /// Fills the page's password field (and its best-guess paired username
    /// field, same heuristic as PasswordDetectionScript's own) with
    /// `username`/`password`, then dispatches `input` and `change` events on
    /// each -- real user typing fires both, and plenty of pages listen for
    /// one or the other to validate/enable a submit button. Values are
    /// JSON-encoded before being embedded in the script so they're always
    /// safe as JS string literals, whatever characters (quotes, newlines,
    /// unicode) the stored credential happens to contain.
    static func fillScript(username: String, password: String) -> String {
        let usernameJSON = jsonStringLiteral(username)
        let passwordJSON = jsonStringLiteral(password)
        return """
        (function(usernameValue, passwordValue) {
          var passwordField = document.querySelector('input[type="password"]');
          if (!passwordField) { return; }
          var scope = passwordField.form || document;
          var candidates = Array.prototype.slice.call(scope.querySelectorAll('input'));
          var passwordIndex = candidates.indexOf(passwordField);
          var usernameField = null;
          for (var i = passwordIndex - 1; i >= 0; i--) {
            var type = (candidates[i].getAttribute('type') || 'text').toLowerCase();
            if (type === 'text' || type === 'email' || type === 'tel' ||
                candidates[i].autocomplete === 'username') {
              usernameField = candidates[i];
              break;
            }
          }
          function setValue(el, value) {
            if (!el) { return; }
            el.value = value;
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          }
          setValue(usernameField, usernameValue);
          setValue(passwordField, passwordValue);
        })(\(usernameJSON), \(passwordJSON));
        """
    }

    private static func jsonStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let json = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return json
    }
}
