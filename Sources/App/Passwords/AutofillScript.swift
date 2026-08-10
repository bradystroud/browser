import Foundation

/// Builds the one-shot script that fills a saved credential into the page
/// (browser-ojh.1). Two callers, both in PasswordManagerCoordinator: the
/// omnibox key icon's click handler, and -- when
/// PasswordAutofillPreference.isAutomaticFillEnabled, which is the default
/// -- once per navigation to a page with a saved credential for its host.
/// See that preference's own doc comment for the clickjacking trade-off
/// automatic filling accepts, and why click-only turned out to be
/// indistinguishable in practice from not remembering the password at all.
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
