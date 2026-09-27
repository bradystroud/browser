import Foundation

/// Middle-click autoscroll, as on Windows and Linux: a middle click on the
/// page (not on a link, which still opens in a new tab through the engine's
/// own middle-click handling) leaves a mark where it was, and the page
/// scrolls towards the pointer, faster the further away it is. Another
/// click, Escape, the wheel, the pointer leaving the page, the window losing
/// focus or switching tabs stops it;
/// pressed, dragged and let go, it stops when the button comes up.
///
/// Page script on both engines: Chromium has this natively only on Windows
/// and Linux, WebKit not at all, and the page is what knows which element
/// under the pointer actually scrolls. Main frame only -- a middle click
/// inside an iframe does nothing special.
///
/// The speed curve is GestureCore's AutoScrollCurve, embedded from Swift so
/// the tested function and the running one are the same.
enum AutoScrollScript {
    /// For pages already showing when the preference is turned off: the
    /// script stays installed but ignores middle clicks.
    static let disable = "window.__brwAutoScrollOff = true;"

    static var source: String {
        """
        (function () {
          window.__brwAutoScrollOff = false;
          if (window.__brwAutoScroll) { return; }
          window.__brwAutoScroll = true;

          var speed = \(AutoScrollCurve.javaScriptFunction);
          var dragReleaseMs = \(AutoScrollCurve.dragReleaseDelay * 1000);
          var deadZone = \(AutoScrollCurve.deadZone);
          var active = null;
          // The button whose press just stopped scrolling: its click belongs
          // to stopping, and must not also follow a link under the pointer.
          var swallow = -1;

          function scroller(el) {
            for (; el && el !== document.body && el !== document.documentElement; el = el.parentElement) {
              var s = getComputedStyle(el);
              if (/(auto|scroll|overlay)/.test(s.overflowY + ' ' + s.overflowX) &&
                  (el.scrollHeight > el.clientHeight + 1 || el.scrollWidth > el.clientWidth + 1)) { return el; }
            }
            return document.scrollingElement || document.documentElement;
          }

          // The origin mark, in a closed shadow root the page's styles can't
          // reach. Built node by node: a Trusted Types page (YouTube, Google)
          // throws on any innerHTML assignment.
          var svgNS = 'http://www.w3.org/2000/svg';
          function svg(tag, attributes) {
            var node = document.createElementNS(svgNS, tag);
            for (var name in attributes) { node.setAttribute(name, attributes[name]); }
            return node;
          }
          function mark(x, y) {
            var host = document.createElement('div');
            host.style.cssText = 'all:initial;position:fixed;z-index:2147483647;pointer-events:none;' +
              'left:' + (x - 15) + 'px;top:' + (y - 15) + 'px;width:30px;height:30px;';
            var picture = svg('svg', { viewBox: '0 0 30 30', width: '30', height: '30',
              style: 'filter:drop-shadow(0 2px 6px rgba(0,0,0,.25))' });
            picture.appendChild(svg('circle', { cx: '15', cy: '15', r: '13.5', fill: 'rgba(255,255,255,.94)', stroke: 'rgba(0,0,0,.18)' }));
            picture.appendChild(svg('path', { d: 'M15 5.5l3.5 4.5h-7zM15 24.5l3.5-4.5h-7zM5.5 15l4.5-3.5v7zM24.5 15l-4.5-3.5v7z', fill: 'rgba(0,0,0,.62)' }));
            picture.appendChild(svg('circle', { cx: '15', cy: '15', r: '1.6', fill: 'rgba(0,0,0,.62)' }));
            host.attachShadow({ mode: 'closed' }).appendChild(picture);
            document.documentElement.appendChild(host);
            return host;
          }

          function tick(now) {
            if (!active) { return; }
            var dt = Math.min(0.05, Math.max(0, (now - active.last) / 1000));
            active.last = now;
            active.carryX += speed(active.dx) * dt;
            active.carryY += speed(active.dy) * dt;
            var stepX = Math.trunc(active.carryX), stepY = Math.trunc(active.carryY);
            active.carryX -= stepX;
            active.carryY -= stepY;
            if (stepX || stepY) { active.target.scrollBy(stepX, stepY); }
            active.frame = requestAnimationFrame(tick);
          }
          function move(e) {
            if (!active) { return; }
            active.dx = e.clientX - active.x;
            active.dy = e.clientY - active.y;
          }
          function stop() {
            if (!active) { return; }
            cancelAnimationFrame(active.frame);
            active.badge.remove();
            document.documentElement.style.cursor = active.cursor;
            removeEventListener('mousemove', move, true);
            active = null;
          }

          addEventListener('mousedown', function (e) {
            swallow = -1;
            if (active) { e.preventDefault(); e.stopPropagation(); stop(); swallow = e.button; return; }
            if (e.button !== 1 || window.__brwAutoScrollOff) { return; }
            var t = e.target;
            if (t && t.closest && t.closest('a[href], area[href], input, textarea, select, button, video, audio, iframe, embed, object, [contenteditable=""], [contenteditable="true"]')) { return; }
            e.preventDefault();
            active = {
              x: e.clientX, y: e.clientY, dx: 0, dy: 0, carryX: 0, carryY: 0,
              since: performance.now(), last: performance.now(),
              target: scroller(t), badge: mark(e.clientX, e.clientY),
              cursor: document.documentElement.style.cursor
            };
            document.documentElement.style.cursor = 'all-scroll';
            addEventListener('mousemove', move, true);
            active.frame = requestAnimationFrame(tick);
          }, true);
          addEventListener('mouseup', function (e) {
            if (active && e.button === 1 && performance.now() - active.since > dragReleaseMs &&
                (Math.abs(active.dx) > deadZone || Math.abs(active.dy) > deadZone)) { stop(); swallow = 1; }
          }, true);
          function eat(e) {
            if (e.button === swallow) { swallow = -1; e.preventDefault(); e.stopPropagation(); }
            else if (e.button === 1 && active) { e.preventDefault(); }
          }
          addEventListener('click', eat, true);
          addEventListener('auxclick', eat, true);
          addEventListener('keydown', function (e) { if (active && e.key === 'Escape') { e.preventDefault(); stop(); } }, true);
          addEventListener('wheel', stop, { capture: true, passive: true });
          addEventListener('blur', stop);
          document.documentElement.addEventListener('mouseleave', stop);
          document.addEventListener('visibilitychange', stop);
        })();
        """
    }
}
