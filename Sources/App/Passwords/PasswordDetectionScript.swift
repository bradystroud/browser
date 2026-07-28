import Foundation

/// The document-start script injected into every top-level navigation via
/// Tab.engineTabDidStartMainFrameLoad (browser-ojh.1). Two jobs, matching
/// the two things the password manager needs to know about a page:
///
/// 1. Existence -- does this page currently have a password field at all?
///    Tracked via a MutationObserver (page content can appear well after
///    the initial document, e.g. client-rendered login forms), reported
///    only on change via a "passwordFieldsPresent" cefQuery message. Chunk 4
///    (the omnibox key icon) is this message's consumer.
/// 2. Submission -- when a form with a filled password field is submitted,
///    capture {origin, username, password} and report it via a
///    "passwordFormSubmit" cefQuery message. SavePasswordPromptController
///    (via PasswordManagerController) is this message's consumer.
///
/// SECURITY: this script never logs the password value anywhere (no
/// console.log, no attribute, nothing DOM-visible beyond the live input
/// element the page itself already rendered) -- it only ever leaves the
/// page via the cefQuery request string, which CEF delivers to native code
/// through its own internal (non-DOM, non-network) IPC. See
/// docs/ai-tasks/password-manager-notes.md's threat-model section for what
/// this does and doesn't protect against -- notably, any *other* script the
/// page itself runs can already read a filled password field's .value the
/// same way this one does; that's inherent to how form autofill/detection
/// works in a web page, not something this script introduces.
enum PasswordDetectionScript {
    static let source = """
    (function() {
      if (window.__brwPasswordWatcher) { return; }
      window.__brwPasswordWatcher = true;

      function send(payload) {
        try {
          window.cefQuery({
            request: JSON.stringify(payload),
            onSuccess: function() {},
            onFailure: function() {}
          });
        } catch (e) {}
      }

      function hasPasswordField() {
        return !!document.querySelector('input[type="password"]');
      }

      var lastReportedPresence = null;
      function reportPresenceIfChanged() {
        var present = hasPasswordField();
        if (present === lastReportedPresence) { return; }
        lastReportedPresence = present;
        send({ type: 'passwordFieldsPresent', origin: location.origin, present: present });
      }

      function isUsernameLikeInput(el) {
        var type = (el.getAttribute('type') || 'text').toLowerCase();
        return type === 'text' || type === 'email' || type === 'tel' ||
          el.autocomplete === 'username';
      }

      function usernameFieldFor(passwordField, scope) {
        var candidates = Array.prototype.slice.call((scope || document).querySelectorAll('input'));
        var passwordIndex = candidates.indexOf(passwordField);
        for (var i = passwordIndex - 1; i >= 0; i--) {
          if (isUsernameLikeInput(candidates[i])) { return candidates[i]; }
        }
        return null;
      }

      function handleSubmit(event) {
        var target = event.target;
        if (!target || typeof target.querySelector !== 'function') { return; }
        var passwordField = target.querySelector('input[type="password"]');
        if (!passwordField || !passwordField.value) { return; }
        var usernameField = usernameFieldFor(passwordField, target);
        send({
          type: 'passwordFormSubmit',
          origin: location.origin,
          username: usernameField ? usernameField.value : '',
          password: passwordField.value
        });
      }

      // Capture phase on document: this fires before any of the form's own
      // handlers (capture runs top-down from window/document to the event's
      // target), so a page calling stopPropagation() in its own submit
      // handler can't suppress this -- and it covers forms added to the DOM
      // after this script ran too, with no per-form wiring needed.
      document.addEventListener('submit', handleSubmit, true);

      reportPresenceIfChanged();
      var observer = new MutationObserver(function() { reportPresenceIfChanged(); });
      observer.observe(document.documentElement || document, { childList: true, subtree: true });
    })();
    """
}
