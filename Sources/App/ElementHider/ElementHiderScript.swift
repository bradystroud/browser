import Foundation

/// The element hider's page scripts: the pick mode, and the "show me which
/// one this is" preview the Hidden Elements sheet uses.
///
/// Injected on demand with EngineTab.executeJavaScript, so they run in the
/// page's own world on both engines, and report back through the shared
/// `cefQuery` channel (PageMessageDispatcher), never a channel of their own.
enum ElementHiderScript {
    static let pickedMessageType = "elementHiderPicked"
    static let endedMessageType = "elementHiderEnded"

    private static let peekStyleId = "__brw-hidden-peek"

    /// Installs the picker if this document has none yet, and turns it on.
    static let start = "(\(picker))(); window.__brwElementHider.on();"

    /// Turns the picker off without reporting back: native code already
    /// knows, since it is the one asking.
    static let stop = "if (window.__brwElementHider) { window.__brwElementHider.off(true); }"

    /// Shows one hidden element again, outlined and scrolled into view,
    /// while leaving the rest hidden. `cssWithout` is the site's sheet minus
    /// that element's rule -- rebuilding the sheet, rather than overriding
    /// one rule with another, brings the element back with the layout it
    /// actually had.
    static func peek(selector: String, cssWithout: String) -> String {
        let outline = "\(selector) { outline: 2px solid #0a84ff !important; outline-offset: 2px !important; }"
        return SiteStyleSheetScript.apply(css: cssWithout) + """
        (function (css, sel) {
          var s = document.getElementById('\(peekStyleId)');
          if (!s) {
            s = document.createElement('style');
            s.id = '\(peekStyleId)';
            (document.head || document.documentElement).appendChild(s);
          }
          s.textContent = css;
          try {
            var el = document.querySelector(sel);
            if (el) { el.scrollIntoView({ block: 'center', behavior: 'smooth' }); }
          } catch (e) {}
        })(\(jsonLiteral(outline)), \(jsonLiteral(selector)));
        """
    }

    /// Ends a peek: the full sheet back in force, the outline gone.
    static func unpeek(css: String) -> String {
        SiteStyleSheetScript.apply(css: css)
            + "(function () { var s = document.getElementById('\(peekStyleId)'); if (s) { s.remove(); } })();"
    }

    private static func jsonLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return text
    }

    /// The pick mode. The overlay lives in a closed shadow root so the
    /// page's own CSS cannot restyle or hide it, and ignores the pointer so
    /// `elementFromPoint` sees straight through it.
    ///
    /// ↑ widens the selection to the parent, ↓ narrows it back again: the
    /// element under the pointer is often a thin wrapper inside the thing
    /// the user actually means.
    private static let picker = """
    function () {
      if (window.__brwElementHider) { return; }

      var host = null, box = null, tag = null;
      var target = null, narrower = [], live = false;

      function overlay() {
        if (host && host.isConnected) { return; }
        host = document.createElement('brw-element-hider');
        host.style.cssText = 'all:initial;position:fixed;inset:0;pointer-events:none;z-index:2147483647;';
        var root = host.attachShadow({ mode: 'closed' });
        box = document.createElement('div');
        box.style.cssText = 'position:fixed;display:none;box-sizing:border-box;pointer-events:none;' +
          'border:2px solid #0a84ff;background:rgba(10,132,255,.12);border-radius:3px;';
        tag = document.createElement('div');
        tag.style.cssText = 'position:absolute;left:0;font:500 11px/1.4 -apple-system,BlinkMacSystemFont,sans-serif;' +
          'color:#fff;background:#0a84ff;padding:1px 6px;border-radius:4px;white-space:nowrap;overflow:hidden;' +
          'text-overflow:ellipsis;max-width:320px;';
        box.appendChild(tag);
        root.appendChild(box);
        document.documentElement.appendChild(host);
      }

      function show(el) {
        overlay();
        var r = el.getBoundingClientRect();
        box.style.display = 'block';
        box.style.left = r.left + 'px';
        box.style.top = r.top + 'px';
        box.style.width = r.width + 'px';
        box.style.height = r.height + 'px';
        tag.textContent = name(el) + '  ·  ' + Math.round(r.width) + '×' + Math.round(r.height);
        tag.style.top = r.top >= 22 ? '-20px' : '2px';
      }

      function hide() {
        if (box) { box.style.display = 'none'; }
      }

      var known = {
        nav: 'Navigation', header: 'Header', footer: 'Footer', aside: 'Sidebar', form: 'Form',
        dialog: 'Dialog', video: 'Video', img: 'Image', button: 'Button', iframe: 'Embed',
        figure: 'Figure', table: 'Table', section: 'Section', article: 'Article'
      };

      function clip(text, n) { return text.length > n ? text.slice(0, n) + '…' : text; }

      function name(el) {
        var said = el.getAttribute('aria-label') || el.getAttribute('title') || el.getAttribute('alt');
        if (said && said.trim()) { return clip(said.trim(), 40); }
        var tagName = el.tagName.toLowerCase();
        if (known[tagName]) { return known[tagName]; }
        var role = el.getAttribute('role');
        if (role) { return role.charAt(0).toUpperCase() + role.slice(1); }
        var text = (el.innerText || '').trim().replace(/\\s+/g, ' ');
        return text ? clip(text, 40) : tagName;
      }

      function shape(el) {
        var r = el.getBoundingClientRect();
        var cx = r.left + r.width / 2, cy = r.top + r.height / 2;
        var side = cx < innerWidth / 3 ? 'left' : (cx > innerWidth * 2 / 3 ? 'right' : 'centre');
        var band = cy < innerHeight / 3 ? 'top' : (cy > innerHeight * 2 / 3 ? 'bottom' : 'middle');
        return Math.round(r.width) + '×' + Math.round(r.height) + ' · ' + band + ' ' + side;
      }

      // Build tools stamp hashes into ids and class names (css-1x2y3z,
      // Button_primary__3xYz1, :r4:) that change on the next deploy; a
      // selector built on one stops matching and the element comes back.
      // State classes (is-open, active) come and go with interaction.
      function steady(word) {
        if (!/^[A-Za-z][\\w-]{1,47}$/.test(word)) { return false; }
        if ((word.match(/\\d/g) || []).length > 2) { return false; }
        if (/^(css|sc|jsx|emotion|svelte|styles?|ember|react|radix|headlessui|mui|chakra|tw)-/i.test(word)) { return false; }
        if (/__[A-Za-z0-9]{5,}$/.test(word) || /_[A-Za-z0-9]{5}$/.test(word) && /\\d/.test(word)) { return false; }
        if (/^(is|has)-/.test(word)) { return false; }
        return !/^(active|open|opened|show|shown|visible|hidden|hover|focus|focused|selected|expanded|collapsed|sticky|fixed|scrolled|loaded|loading)$/i.test(word);
      }

      function esc(s) { return CSS.escape(s); }

      function matches(sel) {
        try { return document.querySelectorAll(sel); } catch (e) { return []; }
      }

      function uniquelyIs(sel, el) {
        var found = matches(sel);
        return found.length === 1 && found[0] === el;
      }

      function classesOf(el) {
        var raw = typeof el.className === 'string' ? el.className : (el.getAttribute('class') || '');
        return raw.trim().split(/\\s+/).filter(function (c) { return c && steady(c); });
      }

      function idSelector(el) {
        return el.id && steady(el.id) ? '#' + esc(el.id) : null;
      }

      var hooks = ['data-testid', 'data-test-id', 'data-test', 'data-qa', 'data-cy', 'data-component',
                   'aria-label', 'name', 'role'];

      function ownSelector(el) {
        var tagName = el.tagName.toLowerCase();
        var byId = idSelector(el);
        if (byId && uniquelyIs(byId, el)) { return byId; }
        for (var i = 0; i < hooks.length; i++) {
          var v = el.getAttribute(hooks[i]);
          if (v && v.length <= 80 && !/[\\u0000-\\u001f{}]/.test(v) &&
              (hooks[i] !== 'aria-label' || !/\\d{2,}/.test(v))) {
            var s = tagName + '[' + hooks[i] + '="' + v.replace(/\\\\/g, '\\\\\\\\').replace(/"/g, '\\\\"') + '"]';
            if (uniquelyIs(s, el)) { return s; }
          }
        }
        var classes = classesOf(el);
        for (var j = 0; j < classes.length; j++) {
          var one = tagName + '.' + esc(classes[j]);
          if (uniquelyIs(one, el)) { return one; }
        }
        if (classes.length > 1) {
          var all = tagName + '.' + classes.slice(0, 4).map(esc).join('.');
          if (uniquelyIs(all, el)) { return all; }
        }
        return null;
      }

      // One step of a path: the tag, a couple of steady classes to make it
      // readable, and a position only when its siblings need telling apart.
      function step(el) {
        var tagName = el.tagName.toLowerCase();
        var s = tagName + classesOf(el).slice(0, 2).map(function (c) { return '.' + esc(c); }).join('');
        var parent = el.parentElement;
        if (parent) {
          var twins = Array.prototype.filter.call(parent.children, function (c) { return c.tagName === el.tagName; });
          if (twins.length > 1) { s = tagName + ':nth-of-type(' + (twins.indexOf(el) + 1) + ')'; }
        }
        return s;
      }

      function selectorFor(el) {
        var own = ownSelector(el);
        if (own) { return own; }
        var parts = [step(el)], node = el.parentElement;
        while (node && node !== document.documentElement) {
          var anchor = node === document.body ? 'body' : ownSelector(node);
          if (anchor) {
            var anchored = anchor + ' > ' + parts.join(' > ');
            if (uniquelyIs(anchored, el)) { return anchored; }
          }
          parts.unshift(step(node));
          if (uniquelyIs(parts.join(' > '), el)) { return parts.join(' > '); }
          if (node === document.body) { break; }
          node = node.parentElement;
        }
        return parts.join(' > ');
      }

      function pickable(el) {
        return el && el.nodeType === 1 && el !== host && el !== document.documentElement && el !== document.body;
      }

      function send(payload) {
        try {
          window.cefQuery({ request: JSON.stringify(payload), onSuccess: function () {}, onFailure: function () {} });
        } catch (e) {}
      }

      function onMove(e) {
        var el = document.elementFromPoint(e.clientX, e.clientY);
        if (!pickable(el) || el === target) { return; }
        target = el;
        narrower = [];
        show(el);
      }

      function swallow(e) {
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
      }

      // Real pages act on pointerdown or mousedown, well before a click
      // completes, so every stage of a press is swallowed, not just click.
      function onPress(e) {
        swallow(e);
        if (e.button !== 0) { return; }
        var el = target || document.elementFromPoint(e.clientX, e.clientY);
        if (!pickable(el)) { return; }
        send({ type: 'elementHiderPicked', selector: selectorFor(el), label: name(el), note: shape(el) });
        target = null;
        narrower = [];
        hide();
      }

      function onKey(e) {
        if (e.key === 'Escape') {
          swallow(e);
          off(false);
        } else if (e.key === 'ArrowUp' && target && pickable(target.parentElement)) {
          swallow(e);
          narrower.push(target);
          target = target.parentElement;
          show(target);
        } else if (e.key === 'ArrowDown' && narrower.length) {
          swallow(e);
          target = narrower.pop();
          show(target);
        }
      }

      function onScroll() { if (target && target.isConnected) { show(target); } else { hide(); } }

      var presses = ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click', 'dblclick',
                     'auxclick', 'contextmenu', 'touchstart'];

      function listen(add) {
        var method = add ? 'addEventListener' : 'removeEventListener';
        window[method]('mousemove', onMove, true);
        window[method]('keydown', onKey, true);
        window[method]('scroll', onScroll, true);
        presses.forEach(function (kind) {
          window[method](kind, kind === 'pointerdown' ? onPress : swallow, true);
        });
      }

      function on() {
        if (live) { return; }
        live = true;
        listen(true);
        document.documentElement.style.setProperty('cursor', 'crosshair', 'important');
      }

      function off(silent) {
        if (!live) { return; }
        live = false;
        listen(false);
        target = null;
        narrower = [];
        if (host) { host.remove(); host = null; }
        document.documentElement.style.removeProperty('cursor');
        if (!silent) { send({ type: 'elementHiderEnded' }); }
      }

      Object.defineProperty(window, '__brwElementHider', {
        value: Object.freeze({ on: on, off: off }),
        enumerable: false
      });
    }
    """
}
