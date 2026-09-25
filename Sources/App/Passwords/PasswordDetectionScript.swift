import Foundation

/// The document-start script injected into every top-level navigation via
/// Tab.engineTabDidStartMainFrameLoad (browser-ojh.1). Three jobs, matching
/// the three things the password manager needs to know about a page:
///
/// 1. Existence -- does this page currently have a password field at all?
///    Tracked via a MutationObserver (page content can appear well after
///    the initial document, e.g. client-rendered login forms), reported
///    only on change via a "passwordFieldsPresent" cefQuery message. The
///    omnibox key icon and automatic fill are this message's consumers.
/// 2. Submission -- something that looks like a login attempt just happened
///    (a real form submit, Enter in a password field, or a click on a
///    submit-like control while a password field is filled): capture
///    {origin, username, password} and report it via a "passwordFormSubmit"
///    message, which prompts to save straight away. The `origin` field is
///    never read natively -- any frame can send any JSON -- the site comes
///    from PageMessage.origin instead.
/// 3. Candidate -- a password field simply *has* a value, reported
///    (debounced) via "passwordCredentialCandidate". The native side holds
///    this as the tab's pending credential and re-decides when the tab
///    navigates. This is what makes the manager work on sites that never
///    fire a submit event at all; see the note on job 3 below.
///
/// ## Why job 3 exists
///
/// v1 of this script listened for `submit` and nothing else, which quietly
/// meant "only classic form-POST logins are ever remembered." Confirmed
/// live against two local test pages: a `<form>` posting normally produced a
/// `passwordFormSubmit`, while a form-less login that does
/// `fetch()`-then-`location.href` (exactly what Google's and most React
/// logins do) produced no message of any kind. Chromium's own password
/// manager solves this browser-side, by holding a provisional credential and
/// deciding whether to offer it once the navigation lands; jobs 2 + 3 are
/// that same shape, split across this script (capture) and
/// PasswordManagerCoordinator (decide on navigate).
///
/// ## Why messages retry
///
/// A cefQuery sent before the native side has wired this tab's message
/// channel is dropped in silence -- neither onSuccess nor onFailure ever
/// runs, because nothing on the other end answers it. PageMessageDispatcher
/// wires new tabs on a 0.5s poll, so a login page loading into a brand-new
/// tab reports its password field before anyone is listening. Since presence
/// is only reported *on change*, that dropped message was never re-sent and
/// the key icon never appeared for the life of that tab -- also confirmed
/// live, and also fixed here: `sendReliable` retries until the native ack
/// arrives. Submission/candidate messages use `sendOnce` instead, since a
/// retry there could double-prompt (the native side is always wired by the
/// time a human has typed a password, so there is nothing to retry for).
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

      var RETRY_MS = 600;
      var MAX_ATTEMPTS = 15;
      var CANDIDATE_DEBOUNCE_MS = 400;

      function sendOnce(payload) {
        try {
          window.cefQuery({
            request: JSON.stringify(payload),
            onSuccess: function() {},
            onFailure: function() {}
          });
        } catch (e) {}
      }

      // Retries until the native side acks (see this script's Swift doc
      // comment for the dropped-message race this exists to survive).
      function sendReliable(payload) {
        var attempts = 0;
        var acked = false;
        function attempt() {
          if (acked || attempts >= MAX_ATTEMPTS) { return; }
          attempts++;
          try {
            window.cefQuery({
              request: JSON.stringify(payload),
              onSuccess: function() { acked = true; },
              onFailure: function() { acked = true; }
            });
          } catch (e) {}
          setTimeout(function() { if (!acked) { attempt(); } }, RETRY_MS);
        }
        attempt();
      }

      function hasPasswordField() {
        return !!document.querySelector('input[type="password"]');
      }

      var lastReportedPresence = null;
      function reportPresenceIfChanged() {
        var present = hasPasswordField();
        if (present === lastReportedPresence) { return; }
        lastReportedPresence = present;
        sendReliable({ type: 'passwordFieldsPresent', origin: location.origin, present: present });
      }

      function isUsernameLikeInput(el) {
        if (!el || el.disabled) { return false; }
        var type = (el.getAttribute('type') || 'text').toLowerCase();
        if (type === 'hidden') { return false; }
        var autocomplete = (el.getAttribute('autocomplete') || '').toLowerCase();
        if (autocomplete.indexOf('username') !== -1 || autocomplete === 'email') { return true; }
        return type === 'text' || type === 'email' || type === 'tel';
      }

      // Scoped to the password field's own form when it has one, and to the
      // whole document when it doesn't -- form-less logins are exactly the
      // case v1 missed, so falling back to the document rather than giving
      // up matters here.
      function usernameFieldFor(passwordField) {
        var scope = passwordField.form || document;
        var candidates = Array.prototype.slice.call(scope.querySelectorAll('input'));
        // An explicit autocomplete=username/email wins over position: a page
        // that bothers to declare it is more reliable than "nearest input
        // above the password field".
        for (var i = 0; i < candidates.length; i++) {
          var declared = (candidates[i].getAttribute('autocomplete') || '').toLowerCase();
          if (declared.indexOf('username') !== -1 || declared === 'email') { return candidates[i]; }
        }
        var passwordIndex = candidates.indexOf(passwordField);
        for (var j = passwordIndex - 1; j >= 0; j--) {
          if (isUsernameLikeInput(candidates[j])) { return candidates[j]; }
        }
        return null;
      }

      function filledPasswordField() {
        var fields = document.querySelectorAll('input[type="password"]');
        for (var i = 0; i < fields.length; i++) {
          if (fields[i].value) { return fields[i]; }
        }
        return null;
      }

      function snapshot() {
        var passwordField = filledPasswordField();
        if (!passwordField) { return null; }
        var usernameField = usernameFieldFor(passwordField);
        return {
          origin: location.origin,
          username: usernameField ? usernameField.value : '',
          password: passwordField.value
        };
      }

      function reportSubmit() {
        var snap = snapshot();
        if (!snap) { return; }
        snap.type = 'passwordFormSubmit';
        sendOnce(snap);
      }

      var lastCandidateKey = null;
      var candidateTimer = null;
      function reportCandidate() {
        var snap = snapshot();
        if (!snap) { return; }
        var key = snap.username + '\\u0000' + snap.password;
        if (key === lastCandidateKey) { return; }
        lastCandidateKey = key;
        snap.type = 'passwordCredentialCandidate';
        sendOnce(snap);
      }
      function scheduleCandidate() {
        if (candidateTimer) { clearTimeout(candidateTimer); }
        candidateTimer = setTimeout(reportCandidate, CANDIDATE_DEBOUNCE_MS);
      }

      // Capture phase on document throughout: capture runs top-down from
      // window/document to the event's target, so it fires before any of the
      // page's own handlers and a page calling stopPropagation() can't
      // suppress it -- and it covers elements added to the DOM after this
      // script ran, with no per-element wiring needed.
      document.addEventListener('submit', function() { reportSubmit(); }, true);

      document.addEventListener('input', function(event) {
        var target = event.target;
        if (!target || !target.tagName || target.tagName.toLowerCase() !== 'input') { return; }
        scheduleCandidate();
      }, true);

      document.addEventListener('keydown', function(event) {
        if (event.key !== 'Enter') { return; }
        var target = event.target;
        if (!target || (target.getAttribute && (target.getAttribute('type') || '').toLowerCase() !== 'password')) { return; }
        // Deferred a tick so the page's own keydown handler has already
        // moved whatever values it moves before the snapshot is taken.
        setTimeout(reportSubmit, 0);
      }, true);

      function isSubmitLike(el) {
        while (el && el !== document) {
          var tag = (el.tagName || '').toLowerCase();
          var type = (el.getAttribute && (el.getAttribute('type') || '')).toLowerCase();
          var role = (el.getAttribute && (el.getAttribute('role') || '')).toLowerCase();
          if (tag === 'button' || role === 'button' || type === 'submit' || type === 'button') { return true; }
          el = el.parentNode;
        }
        return false;
      }

      document.addEventListener('click', function(event) {
        if (!filledPasswordField()) { return; }
        if (!isSubmitLike(event.target)) { return; }
        setTimeout(reportSubmit, 0);
      }, true);

      reportPresenceIfChanged();
      var observer = new MutationObserver(function() { reportPresenceIfChanged(); });
      observer.observe(document.documentElement || document, { childList: true, subtree: true });
    })();
    """
}
