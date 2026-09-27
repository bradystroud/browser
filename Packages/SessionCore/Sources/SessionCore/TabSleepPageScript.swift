import Foundation

/// The page half of tab sleep: a document-start script that keeps a marker
/// attribute on `<html>` saying whether the page holds typed input nobody has
/// sent, whether it has a beforeunload guard, whether a video is in picture
/// in picture, and how far down the page is scrolled. The app reads it back
/// with the engine's page-source call just before releasing a tab -- the same
/// marker-and-page-source channel the audio indicator uses, because CEF's
/// executeJavaScript returns nothing.
///
/// Typed input is judged by what is still in the field, not by whether an
/// `input` event ever fired: a chat box a page empties itself after sending
/// fires no event on the way out, so `refreshSource` re-checks each edited
/// field just before the read. The script runs in the main frame only, so a
/// frame it can't see into counts as holding input once it has had focus.
///
/// A beforeunload prompt is how an editor with unsaved work (a document app,
/// an autosave still pending) asks not to be closed, and sleep closes the
/// engine tab without running it. So the refresh asks the page directly: it
/// dispatches a synthetic BeforeUnloadEvent and checks whether any handler
/// cancelled it or set a message, the two ways a handler asks for the prompt.
/// Asking rather than watching addEventListener matters: the script is not
/// guaranteed to run before the page's own inline scripts on either engine,
/// and a handler registered earlier would be invisible. A synthetic event
/// shows no dialog; handlers that only log or flush run once more, which is
/// the price of not guessing.
enum TabSleepPageScript {
    static let markerAttribute = "data-brw-sleep-state"

    static let source = """
    (function() {
      if (window.__brwSleepWatcher) { return; }
      window.__brwSleepWatcher = true;

      var edited = [];
      var frameFocused = false;
      var unload = 0;
      var pip = 0;
      var written = null;
      var ignoredTypes = /^(checkbox|radio|range|color|file|hidden|submit|button|reset|image)$/i;

      function holdsText(el) {
        if (!el.isConnected) { return false; }
        if (el.isContentEditable) { return (el.textContent || '').trim().length > 0; }
        return (el.value || '').trim().length > 0;
      }

      function noteFocusedFrame() {
        var active = document.activeElement;
        if (active && (active.tagName === 'IFRAME' || active.tagName === 'FRAME')) { frameFocused = true; }
      }

      function probeBeforeUnload() {
        unload = 0;
        try {
          var event = document.createEvent('BeforeUnloadEvent');
          event.initEvent('beforeunload', false, true);
          window.dispatchEvent(event);
          var message = event.returnValue;
          if (event.defaultPrevented || (typeof message === 'string' && message.length > 0)) { unload = 1; }
        } catch (error) {}
      }

      function write() {
        noteFocusedFrame();
        edited = edited.filter(holdsText);
        var input = edited.length || frameFocused ? 1 : 0;
        var y = Math.max(0, Math.round(window.scrollY || 0));
        var value = 'input=' + input + ';unload=' + unload + ';pip=' + pip + ';y=' + y;
        if (value === written || !document.documentElement) { return; }
        written = value;
        document.documentElement.setAttribute('\(markerAttribute)', value);
      }
      window.__brwSleepRefresh = function() { probeBeforeUnload(); write(); };

      document.addEventListener('input', function(event) {
        var el = (event.composedPath && event.composedPath()[0]) || event.target;
        if (!el || !el.tagName) { return; }
        var isField = el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT' && !ignoredTypes.test(el.type || ''));
        if (!isField && !el.isContentEditable) { return; }
        if (edited.indexOf(el) < 0) { edited.push(el); }
        write();
      }, true);
      window.addEventListener('blur', function() { setTimeout(write, 0); });
      document.addEventListener('enterpictureinpicture', function() { pip = 1; write(); }, true);
      document.addEventListener('leavepictureinpicture', function() { pip = 0; write(); }, true);
      document.addEventListener('webkitpresentationmodechanged', function(event) {
        var mode = event.target && event.target.webkitPresentationMode;
        pip = mode === 'picture-in-picture' ? 1 : 0;
        write();
      }, true);

      var scrollTimer = null;
      window.addEventListener('scroll', function() {
        if (scrollTimer) { return; }
        scrollTimer = setTimeout(function() { scrollTimer = null; write(); }, 500);
      }, { passive: true });
    })();
    """

    /// Brings the marker up to date right before the page source is read.
    static let refreshSource = "window.__brwSleepRefresh && window.__brwSleepRefresh();"

    /// Scrolls a woken page back to where it was left, unless the page has
    /// already put itself somewhere else. Tried again shortly after, for pages
    /// whose content arrives after the load finishes.
    static func restoreScrollSource(y: Int) -> String {
        """
        (function() {
          var y = \(max(0, y));
          function go() { if (window.scrollY < 1) { window.scrollTo(0, y); } }
          go();
          setTimeout(go, 600);
          setTimeout(go, 1500);
        })();
        """
    }

    /// Reads the marker from the document's real `<html>` start tag: not one
    /// inside a comment (old IE conditional comments carry their own `<html`
    /// tags ahead of the real one), and not the attribute's name merely
    /// appearing in the page's text. A page that never ran the script reports
    /// nothing held.
    static func pageState(fromSource source: String) -> TabSleepPageState {
        guard let tag = rootStartTag(in: source),
              let attributeStart = tag.range(of: "\(markerAttribute)=\"") else { return TabSleepPageState() }
        let valueStart = attributeStart.upperBound
        guard let valueEnd = tag[valueStart...].firstIndex(of: "\"") else { return TabSleepPageState() }

        var state = TabSleepPageState()
        for field in tag[valueStart..<valueEnd].split(separator: ";") {
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = String(parts[1])
            switch parts[0] {
            case "input": state.hasUnsavedInput = value == "1"
            case "unload": state.hasBeforeUnloadHandler = value == "1"
            case "pip": state.isInPictureInPicture = value == "1"
            case "y": state.scrollY = Int(value).flatMap { $0 >= 0 ? $0 : nil }
            default: continue
            }
        }
        return state
    }

    /// The attributes of the first `<html` start tag outside any comment.
    private static func rootStartTag(in source: String) -> Substring? {
        var cursor = source.startIndex
        while cursor < source.endIndex {
            let comment = source.range(of: "<!--", range: cursor..<source.endIndex)
            let html = source.range(of: "<html", options: .caseInsensitive, range: cursor..<source.endIndex)
            guard let html else { return nil }
            if let comment, comment.lowerBound < html.lowerBound {
                guard let commentEnd = source.range(of: "-->", range: comment.upperBound..<source.endIndex) else { return nil }
                cursor = commentEnd.upperBound
                continue
            }
            guard let tagEnd = source.range(of: ">", range: html.upperBound..<source.endIndex) else { return nil }
            return source[html.upperBound..<tagEnd.lowerBound]
        }
        return nil
    }
}
