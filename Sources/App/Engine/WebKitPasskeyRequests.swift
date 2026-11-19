import Foundation
import WebKit

/// Keeps a WebKit tab's passkey requests from blocking passkeys everywhere
/// else in the app.
///
/// `AuthenticationServicesAgent` gives this app one open passkey request at a
/// time, for every tab and both engines together, and refuses each new one
/// (`AuthorizationError Code=1`, no sheet) while an older one is open. WebKit
/// does not end a request when its page goes: a conditional (autofill)
/// request stays open in the agent after its page navigates, its tab closes,
/// or the app quits, until the agent restarts. Sign-in pages start one as
/// they load (GitHub's does), so one sign-in page left open in any tab, or
/// visited once, blocked every later passkey sign-in. The only thing that
/// ends a request at the agent is the page's own `AbortSignal`, and only
/// while the request is still the open one: a new request that the agent
/// refused leaves the older one impossible to cancel at all.
///
/// So a document-start script in every frame (`WebKitPasskeyScript`) wraps
/// `navigator.credentials.get`/`create` for `publicKey` requests and gives
/// each request a signal of its own:
/// - Before a modal request (a sign-in button, a registration) starts, the
///   document's other requests are ended first. A conditional request is
///   only suspended: the page's promise stays pending and the request starts
///   again, with the same options, once no modal request is open.
/// - A conditional request is suspended while the document is hidden (a
///   background tab, a minimized window) and on `pagehide` (navigation, and
///   the back/forward cache), and starts again when it is shown. It always
///   starts after a delay (`conditionalStartDelayMs`), never at once.
/// - `WebKitTab.close()` ends every request through `endAll`, because a
///   closing web view runs no `pagehide`. Tab sleep closes the engine tab the
///   same way.
/// Other credential types (passwords, federated, OTP) pass through untouched.
final class WebKitPasskeyRequests {
    private let hookName = "__brwPasskeys" + UUID().uuidString.replacingOccurrences(of: "-", with: "")

    func install(into userContentController: WKUserContentController) {
        userContentController.addUserScript(WKUserScript(
            source: WebKitPasskeyScript.source(hookName: hookName),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page))
    }

    /// Ends every passkey request of the main frame's document and calls
    /// `completion` once the page has done so (or could not be reached).
    func endAll(in webView: WKWebView, completion: @escaping () -> Void) {
        webView.evaluateJavaScript(WebKitPasskeyScript.endAllCall(hookName: hookName), in: nil, in: .page) { _ in
            completion()
        }
    }
}

enum WebKitPasskeyScript {
    static func source(hookName: String) -> String {
        "(\(body))(\(jsonString(hookName)), window.CredentialsContainer && window.CredentialsContainer.prototype, \(conditionalStartDelayMs));"
    }

    /// How long a conditional request waits before it starts or starts
    /// again. Showing one tab hides another, and closing a tab shows the next
    /// one, in two web processes with no ordering between them. The request
    /// of the tab that went away must reach the agent as cancelled first: a
    /// new request the agent refuses leaves the older one open for good.
    static let conditionalStartDelayMs = 500

    static func endAllCall(hookName: String) -> String {
        "(function () { var f = window[\(jsonString(hookName))]; if (typeof f === 'function') f(); })(); undefined;"
    }

    private static func jsonString(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
        return String(data: data, encoding: .utf8) ?? "\"\""
    }

    /// `proto` is the object whose `get`/`create` are wrapped: the real
    /// `CredentialsContainer.prototype` in a tab, a stand-in in the tests.
    static let body = """
    function (HOOK, proto, startDelay) {
      'use strict';
      if (!proto || typeof proto.get !== 'function' || typeof proto.create !== 'function') return;
      var w = window, doc = document;
      var apply = Reflect.apply, defProp = Object.defineProperty, getDesc = Object.getOwnPropertyDescriptor;
      var AC = w.AbortController;
      if (typeof AC !== 'function') return;
      var acAbort = AC.prototype.abort;
      var acSignal = getDesc(AC.prototype, 'signal').get;
      var sigAborted = getDesc(AbortSignal.prototype, 'aborted').get;
      var sigReason = (getDesc(AbortSignal.prototype, 'reason') || {}).get;
      var addListener = EventTarget.prototype.addEventListener;
      var removeListener = EventTarget.prototype.removeEventListener;
      var Prom = Promise, then = Prom.prototype.then, reject = Prom.reject.bind(Prom);
      var later = w.setTimeout.bind(w);
      var origGet = proto.get, origCreate = proto.create;

      // The open conditional request, if any. Older conditional requests the
      // page replaced are dropped: they stay pending unless the page aborts
      // them, and never start again.
      var conditional = null;
      // Controllers of the open modal requests.
      var modals = [];
      var pageGone = false, closed = false, startTimer = 0;
      var clearLater = w.clearTimeout.bind(w);

      function isPublicKey(options) {
        return options !== null && typeof options === 'object' && options.publicKey != null;
      }
      function signalOf(options) {
        var s = options.signal;
        return s instanceof AbortSignal ? s : null;
      }
      function aborted(signal) { return apply(sigAborted, signal, []); }
      function reasonOf(signal) { return sigReason ? apply(sigReason, signal, []) : undefined; }
      function abort(ctl, reason) {
        apply(acAbort, ctl, reason === undefined ? [] : [reason]);
      }
      function withSignal(options, ctl) {
        var copy = {};
        for (var key in options) copy[key] = options[key];
        copy.signal = apply(acSignal, ctl, []);
        return copy;
      }
      function isHidden() { return doc.visibilityState === 'hidden'; }

      function scheduleStart() {
        if (startTimer) clearLater(startTimer);
        startTimer = later(function () { startTimer = 0; startConditional(); }, startDelay);
      }

      function startConditional() {
        var entry = conditional;
        if (!entry || entry.ctl || closed || pageGone || modals.length > 0 || isHidden()) return;
        var ctl = new AC();
        entry.ctl = ctl;
        var attempt;
        try {
          attempt = apply(origGet, entry.container, [withSignal(entry.options, ctl)]);
        } catch (error) {
          finishConditional(entry);
          entry.reject(error);
          return;
        }
        apply(then, Prom.resolve(attempt), [function (value) {
          if (entry.done) return;
          finishConditional(entry);
          entry.resolve(value);
        }, function (error) {
          // A rejection of an attempt this script suspended is not the page's.
          if (entry.done || entry.ctl !== ctl) return;
          finishConditional(entry);
          entry.reject(error);
        }]);
      }

      function suspendConditional() {
        if (startTimer) { clearLater(startTimer); startTimer = 0; }
        var entry = conditional;
        if (!entry || !entry.ctl) return;
        var ctl = entry.ctl;
        entry.ctl = null;
        abort(ctl);
      }

      function finishConditional(entry) {
        entry.done = true;
        if (conditional === entry) conditional = null;
        if (entry.ctl) { var ctl = entry.ctl; entry.ctl = null; abort(ctl); }
        if (entry.pageSignal) apply(removeListener, entry.pageSignal, ['abort', entry.onPageAbort]);
      }

      function requestConditional(container, options) {
        var pageSignal = signalOf(options);
        if (pageSignal && aborted(pageSignal)) return apply(origGet, container, [options]);
        if (conditional) {
          suspendConditional();
          conditional = null;
        }
        var entry = { container: container, options: options, pageSignal: pageSignal, ctl: null, done: false };
        var promise = new Prom(function (resolve, rejectEntry) { entry.resolve = resolve; entry.reject = rejectEntry; });
        if (pageSignal) {
          entry.onPageAbort = function () {
            if (entry.done) return;
            finishConditional(entry);
            entry.reject(reasonOf(pageSignal));
          };
          apply(addListener, pageSignal, ['abort', entry.onPageAbort]);
        }
        conditional = entry;
        scheduleStart();
        return promise;
      }

      function requestModal(original, container, options) {
        var pageSignal = signalOf(options);
        if (pageSignal && aborted(pageSignal)) return apply(original, container, [options]);
        suspendConditional();
        var others = modals;
        modals = [];
        for (var i = 0; i < others.length; i++) abort(others[i]);
        var ctl = new AC();
        modals.push(ctl);
        var onPageAbort = function () { abort(ctl, reasonOf(pageSignal)); };
        if (pageSignal) apply(addListener, pageSignal, ['abort', onPageAbort]);
        var settle = function () {
          var index = modals.indexOf(ctl);
          if (index >= 0) modals.splice(index, 1);
          if (pageSignal) apply(removeListener, pageSignal, ['abort', onPageAbort]);
          if (modals.length === 0) scheduleStart();
        };
        var attempt;
        try {
          attempt = apply(original, container, [withSignal(options, ctl)]);
        } catch (error) {
          settle();
          return reject(error);
        }
        return apply(then, Prom.resolve(attempt), [function (value) { settle(); return value; },
                                                   function (error) { settle(); throw error; }]);
      }

      function endAll(final) {
        suspendConditional();
        var open = modals;
        modals = [];
        for (var i = 0; i < open.length; i++) abort(open[i]);
        if (final) closed = true;
      }

      var wrapped = {
        get: function get(options) {
          if (closed || !isPublicKey(options)) return apply(origGet, this, arguments);
          return options.mediation === 'conditional'
            ? requestConditional(this, options)
            : requestModal(origGet, this, options);
        },
        create: function create(options) {
          if (closed || !isPublicKey(options)) return apply(origCreate, this, arguments);
          return requestModal(origCreate, this, options);
        }
      };
      ['get', 'create'].forEach(function (name) {
        var desc = getDesc(proto, name);
        desc.value = wrapped[name];
        defProp(proto, name, desc);
      });

      addListener.call(doc, 'visibilitychange', function () {
        if (isHidden()) suspendConditional(); else scheduleStart();
      }, true);
      addListener.call(w, 'pagehide', function () { pageGone = true; endAll(false); }, true);
      addListener.call(w, 'pageshow', function () { pageGone = false; scheduleStart(); }, true);
      defProp(w, HOOK, { value: function () { endAll(true); }, enumerable: false, configurable: false, writable: false });
    }
    """
}
