import Foundation

/// The document-start script injected into every top-level navigation via
/// Tab.engineTabDidStartMainFrameLoad (browser-rhi.4) -- reports whether the
/// page currently has any `<audio>`/`<video>` element actually playing sound
/// (not paused, not muted *by the page itself*, non-zero volume). This is
/// deliberately independent of Tab.isMuted (the browser-level mute this app
/// applies via CefBrowserHost::SetAudioMuted) -- a tab the user has muted can
/// still be "audible" in this sense (it would be making noise if not for our
/// external mute), matching Safari's own distinction between "playing" and
/// "muted" tab-icon states.
///
/// CEF exposes no native "is this browser currently outputting audio"
/// callback (checked: no such method on CefBrowserHost/CefClient handlers in
/// this project's pinned CEF 150.0.14 headers, unlike SetAudioMuted/
/// IsAudioMuted which ARE real) -- so unlike muting itself, this indicator
/// genuinely needs the JS-injection workaround the task anticipated.
///
/// Reports via a marker attribute on `<html>`, read back through
/// getPageSource(completion:) polling (TabAudioCoordinator), the same
/// pattern ReaderModeController/ReaderTemplate already established for their
/// own "is this page readerable" signal -- deliberately NOT the cefQuery
/// page-message channel PasswordDetectionScript/PaymentAddressDetectionScript
/// use: that channel has exactly one consumer slot per tab (Tab.onPageMessage
/// is a single closure, already claimed by PasswordManagerCoordinator), and
/// this signal is coarse/polling-tolerant enough (a ~1s lag before the
/// speaker icon appears/disappears is fine) that it doesn't need a dedicated
/// new channel of its own the way browser-7jz.3's Notifications bridge did.
enum AudioStateScript {
    static let markerAttribute = "data-brw-audible"

    static let source = """
    (function() {
      if (window.__brwAudioWatcher) { return; }
      window.__brwAudioWatcher = true;

      function isElementAudible(el) {
        return !el.paused && !el.ended && !el.muted && el.volume > 0;
      }

      function computeAudible() {
        var elements = document.querySelectorAll('audio, video');
        for (var i = 0; i < elements.length; i++) {
          if (isElementAudible(elements[i])) { return true; }
        }
        return false;
      }

      var lastReported = null;
      function reportIfChanged() {
        var audible = computeAudible();
        if (audible === lastReported) { return; }
        lastReported = audible;
        document.documentElement.setAttribute('\(markerAttribute)', audible ? 'true' : 'false');
      }

      var mediaEvents = ['play', 'pause', 'ended', 'volumechange', 'emptied'];
      function wire(el) {
        if (el.__brwAudioWired) { return; }
        el.__brwAudioWired = true;
        mediaEvents.forEach(function(name) {
          el.addEventListener(name, reportIfChanged, true);
        });
      }

      function wireAll() {
        var elements = document.querySelectorAll('audio, video');
        for (var i = 0; i < elements.length; i++) { wire(elements[i]); }
      }

      wireAll();
      reportIfChanged();

      // Catches media elements added after this script ran (client-rendered
      // players, ads, SPA route changes) -- same MutationObserver approach
      // PasswordDetectionScript already uses for dynamically-added forms.
      var observer = new MutationObserver(function() {
        wireAll();
        reportIfChanged();
      });
      observer.observe(document.documentElement || document, { childList: true, subtree: true });
    })();
    """

    /// Mirrors ReaderTemplate.isMarkedReaderable(inSource:)'s exact
    /// technique -- a plain substring check against the marker attribute's
    /// last-written value, no HTML parsing needed.
    static func isMarkedAudible(inSource source: String) -> Bool {
        source.contains("\(markerAttribute)=\"true\"")
    }
}
