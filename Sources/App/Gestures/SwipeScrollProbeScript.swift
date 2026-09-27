import Foundation

/// Tells SwipeNavigationController whether a sideways trackpad swipe belongs
/// to the page. Injected on every top-level navigation, and only for an
/// engine without a native swipe of its own (CEF: Chromium's history swipe
/// lives in Chrome's browser layer, which an Alloy-style embedder never
/// gets).
///
/// On every sideways wheel event it walks the event's composed path and
/// asks whether anything there could still scroll in the event's direction
/// (a carousel, a wide table, the page itself), and, once the event has
/// finished dispatching, whether any of the page's own listeners called
/// preventDefault() (a map, a slideshow that handles wheel itself). Either
/// one makes the swipe "taken".
///
/// SwipeNavigationController calls `resetGesture(id)` when fingers go down.
/// The first sideways event after that always reports, tagged with the id,
/// and later ones only when the answer changes, so a carousel still gliding
/// from the previous swipe can neither stay silent (which the tracker would
/// read as free) nor answer for the new gesture. The walk up the event path
/// runs only on that first event and when the direction flips, not on every
/// event of a long glide.
///
/// A wheel event over an iframe is dispatched in the iframe's document and
/// never reaches this one, and a cross-origin frame cannot be asked. So the
/// script also reports, on pointer movement, whether the pointer is over a
/// frame, and the controller leaves every swipe that starts there to the
/// page -- an embedded map or video player is exactly what must not be
/// fought.
enum SwipeScrollProbeScript {
    static let messageType = "swipeScrollState"
    static let resetFunction = "__brwSwipeProbeReset"

    /// Starts gesture `id` in the page; see the type's doc comment.
    static func resetGesture(_ id: Int) -> String {
        "window.\(resetFunction) && window.\(resetFunction)(\(id));"
    }

    /// Whether this engine needs the page's help at all.
    static var isNeeded: Bool { !ActiveEngine.capabilities.nativeSwipeNavigation }

    static let source = """
    (function () {
      if (window.__brwSwipeProbe) { return; }
      window.__brwSwipeProbe = true;

      // null so the first pointer movement on a new document always reports.
      var overFrame = null;
      var gesture = 0, fresh = true, lastTaken = null, lastSign = 0, scrollable = false;

      function send(payload) {
        payload.type = '\(messageType)';
        try {
          window.cefQuery({ request: JSON.stringify(payload), onSuccess: function () {}, onFailure: function () {} });
        } catch (e) {}
      }

      function scrollsX(el, root) {
        var style = getComputedStyle(el);
        var overflow = style.overflowX;
        if (root) {
          var html = getComputedStyle(document.documentElement).overflowX;
          var body = document.body ? getComputedStyle(document.body).overflowX : 'visible';
          overflow = html === 'visible' ? body : html;
          return overflow !== 'hidden' && overflow !== 'clip';
        }
        return overflow === 'auto' || overflow === 'scroll' || overflow === 'overlay';
      }

      function canScrollToward(el, root, deltaX) {
        if (!scrollsX(el, root)) { return false; }
        var box = root ? (document.scrollingElement || document.documentElement) : el;
        var width = root ? window.innerWidth : box.clientWidth;
        var range = box.scrollWidth - width;
        if (range <= 1) { return false; }
        var rtl = getComputedStyle(box).direction === 'rtl';
        var position = box.scrollLeft;
        var min = rtl ? -range : 0, max = rtl ? 0 : range;
        return deltaX > 0 ? position < max - 1 : position > min + 1;
      }

      function taken(e) {
        var path = e.composedPath ? e.composedPath() : [];
        for (var i = 0; i < path.length; i++) {
          var node = path[i];
          if (!node || node.nodeType !== 1) { continue; }
          var root = node === document.documentElement || node === document.body;
          if (canScrollToward(node, root, e.deltaX)) { return true; }
          if (root) { return false; }
        }
        return canScrollToward(document.documentElement, true, e.deltaX);
      }

      try {
        Object.defineProperty(window, '\(resetFunction)', {
          value: function (id) { gesture = id; fresh = true; lastTaken = null; lastSign = 0; },
          configurable: false, enumerable: false, writable: false
        });
      } catch (e) {}

      window.addEventListener('wheel', function (e) {
        if (Math.abs(e.deltaX) <= Math.abs(e.deltaY)) { return; }
        var sign = e.deltaX > 0 ? 1 : -1;
        var first = fresh;
        if (first || sign !== lastSign) { scrollable = taken(e); }
        fresh = false;
        lastSign = sign;
        var id = gesture, found = scrollable;
        setTimeout(function () {
          var answer = found || e.defaultPrevented;
          if (id !== gesture || (!first && answer === lastTaken)) { return; }
          lastTaken = answer;
          send({ taken: answer, gesture: id });
        }, 0);
      }, { passive: true, capture: true });

      function framed(el) {
        return !!el && el.nodeType === 1 && /^(IFRAME|FRAME|EMBED|OBJECT)$/.test(el.tagName);
      }
      function setOverFrame(value) {
        if (value === overFrame) { return; }
        overFrame = value;
        send({ overFrame: value });
      }
      document.addEventListener('pointerover', function (e) {
        var path = e.composedPath ? e.composedPath() : [e.target];
        setOverFrame(framed(path[0]));
      }, { passive: true, capture: true });
      document.addEventListener('pointerout', function (e) {
        if (!e.relatedTarget) { setOverFrame(false); }
      }, { passive: true, capture: true });
    })();
    """
}
