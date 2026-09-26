import Foundation

/// The document-start script behind email suggestions, injected alongside
/// PasswordDetectionScript and PaymentAddressDetectionScript.
///
/// It reports, main frame only (PageMessagePolicy enforces the same thing
/// natively, from the engine's own frame information):
///   - `emailFieldFocused` / `emailFieldInput`: an email-like field is
///     focused or its text changed, with its current value and its box in
///     viewport CSS pixels so the native popup can sit under it. Scrolling
///     and resizing re-send `emailFieldInput` so the popup follows the field.
///   - `emailFieldBlurred`: focus left it, with the value it was left
///     holding, which the native side keeps as a candidate to learn if the
///     tab then navigates (Microsoft's sign-in submits with `form.submit()`,
///     which fires no submit event).
///   - `emailFieldSubmitted`: a form holding an email-like field was
///     submitted, with that field's value.
///
/// A field is email-like when it is `type=email`; or a text field whose
/// `autocomplete` names `email` or `username`, whose name/id/placeholder/
/// aria-label mentions e-mail, or which is Microsoft's `loginfmt`. The
/// focus message also says whether the field's form has a password field,
/// so the native side can stand aside for the password manager there.
///
/// Nothing reported here is trusted for where the page is: the native side
/// only ever uses the engine's verified origin and URL.
enum EmailFieldDetectionScript {
    static let source = """
    (function() {
      if (window.top !== window) { return; }
      if (window.__brwEmailWatcher) { return; }
      window.__brwEmailWatcher = true;

      function send(payload) {
        try {
          window.cefQuery({ request: JSON.stringify(payload), onSuccess: function() {}, onFailure: function() {} });
        } catch (e) {}
      }

      var TEXT_TYPES = { '': 1, 'text': 1, 'email': 1 };

      function isEmailLike(el) {
        if (!el || el.tagName !== 'INPUT' || el.disabled || el.readOnly) { return false; }
        var type = (el.getAttribute('type') || '').toLowerCase();
        if (!TEXT_TYPES[type]) { return false; }
        if (type === 'email') { return true; }
        var autocomplete = (el.getAttribute('autocomplete') || '').toLowerCase().split(/\\s+/);
        if (autocomplete.indexOf('email') !== -1 || autocomplete.indexOf('username') !== -1) { return true; }
        var name = (el.getAttribute('name') || '').toLowerCase();
        if (name === 'loginfmt') { return true; }
        var haystack = (name + ' ' + (el.getAttribute('id') || '') + ' ' + (el.getAttribute('placeholder') || '') + ' ' +
          (el.getAttribute('aria-label') || '')).toLowerCase();
        return /e-?mail/.test(haystack);
      }

      function hasPasswordField(el) {
        var scope = el.form || document;
        return !!scope.querySelector('input[type="password"]');
      }

      function box(el) {
        var r = el.getBoundingClientRect();
        return { x: r.left, y: r.top, width: r.width, height: r.height,
                 viewportWidth: window.innerWidth, viewportHeight: window.innerHeight };
      }

      var current = null;
      window.__brwEmailLastField = null;
      // Set by the fill script while it writes a chosen address, so its own
      // input event does not reopen the popup it just closed.
      window.__brwEmailSuppress = false;

      function report(type, el) {
        var payload = box(el);
        payload.type = type;
        payload.value = el.value || '';
        if (type === 'emailFieldFocused') { payload.hasPasswordField = hasPasswordField(el); }
        send(payload);
      }

      document.addEventListener('focusin', function(event) {
        var el = event.target;
        if (!isEmailLike(el)) { return; }
        current = el;
        window.__brwEmailLastField = el;
        report('emailFieldFocused', el);
      }, true);

      // An autofocused field (Microsoft's sign-in) is focused before the
      // user ever touches it; a click on it asks for suggestions again.
      document.addEventListener('mousedown', function(event) {
        var el = event.target;
        if (el !== document.activeElement || !isEmailLike(el)) { return; }
        current = el;
        window.__brwEmailLastField = el;
        report('emailFieldFocused', el);
      }, true);

      document.addEventListener('input', function(event) {
        if (event.target !== current || window.__brwEmailSuppress) { return; }
        report('emailFieldInput', current);
      }, true);

      document.addEventListener('focusout', function(event) {
        var el = event.target;
        if (el !== current) { return; }
        setTimeout(function() {
          if (document.activeElement === el) { return; }
          if (current === el) { current = null; }
          send({ type: 'emailFieldBlurred', value: el.value || '' });
        }, 0);
      }, true);

      document.addEventListener('submit', function(event) {
        var form = event.target;
        if (!form || typeof form.querySelectorAll !== 'function') { return; }
        var inputs = form.querySelectorAll('input');
        for (var i = 0; i < inputs.length; i++) {
          if (isEmailLike(inputs[i]) && inputs[i].value) {
            send({ type: 'emailFieldSubmitted', value: inputs[i].value });
            return;
          }
        }
      }, true);

      var pending = false;
      function follow() {
        if (!current || pending) { return; }
        pending = true;
        requestAnimationFrame(function() {
          pending = false;
          if (current && document.activeElement === current) { report('emailFieldInput', current); }
        });
      }
      window.addEventListener('scroll', follow, true);
      window.addEventListener('resize', follow, true);
    })();
    """

    /// Writes `email` into the email field the user last focused, then fires
    /// `input` and `change` the way typing would. The value goes through the
    /// prototype's setter so frameworks that wrap `value` (React) see it.
    ///
    /// Does nothing unless it runs in the top frame of a document at
    /// `expectedOrigin` -- the same guard AutofillScript uses, because the
    /// script is evaluated asynchronously and the tab may have moved on.
    static func fillScript(email: String, expectedOrigin: WebOrigin) -> String {
        """
        (function(email, expectedOrigin) {
          if (window.top !== window || location.origin !== expectedOrigin) { return; }
          var el = window.__brwEmailLastField;
          if (!el || !el.isConnected) { return; }
          var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
          window.__brwEmailSuppress = true;
          try {
            setter.call(el, email);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          } finally {
            window.__brwEmailSuppress = false;
          }
          if (document.activeElement !== el) { el.focus(); }
        })(\(jsonStringLiteral(email)), \(jsonStringLiteral(expectedOrigin.serialized)));
        """
    }

    private static func jsonStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let json = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return json
    }
}
