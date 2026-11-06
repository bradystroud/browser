import Foundation

/// The JavaScript the `browser page` commands run in an agent page's main
/// frame. `install` defines `window.__brwAgent` once per document; every
/// command prepends it, so a navigation that drops it costs nothing.
///
/// Element refs ("e12") live in that document's own maps, so a ref stays
/// bound to one element for as long as the document keeps it, and a new
/// document starts again from e1.
enum AgentPageScript {
    /// Wraps `body` (which sees the helper as `A` and must `return` a
    /// JSON-compatible value) in an async function expression and calls it.
    static func call(_ body: String) -> String {
        "(async () => { const A = (\(install)); \(body) })()"
    }

    /// A JS string literal for `value`.
    static func literal(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    /// `{ref}`, `{selector}` or `{text}` as a JS object literal. `role`
    /// narrows a selector or text match to elements of that role.
    static func target(ref: String?, selector: String?, text: String?, role: String? = nil) -> String {
        let roleField = role.map { ", role: \(literal($0))" } ?? ""
        if let ref { return "{ref: \(literal(ref))}" }
        if let selector { return "{selector: \(literal(selector))\(roleField)}" }
        if let text { return "{text: \(literal(text))\(roleField)}" }
        return "null"
    }

    private static let install = #"""
    window.__brwAgent || (window.__brwAgent = (() => {
      const refToElement = new Map();
      const elementToRef = new WeakMap();
      let nextRef = 1;
      const CURSOR_ATTR = 'data-brw-agent-cursor';

      // Activity the page is still busy with, for `--wait-idle`: requests
      // in flight (fetch and XMLHttpRequest, counted here because the page
      // has no other way to see a pending one) and the time of the last DOM
      // change or request completion. Installed once per document, before
      // any command acts, so the activity a click starts is counted.
      let inflight = 0;
      let lastActivity = performance.now();
      const touch = () => { lastActivity = performance.now(); };
      const settled = () => { inflight = Math.max(0, inflight - 1); touch(); };
      if (typeof window.fetch === 'function') {
        const nativeFetch = window.fetch;
        window.fetch = function (...args) {
          inflight++; touch();
          let result;
          try { result = nativeFetch.apply(this, args); } catch (e) { settled(); throw e; }
          return Promise.resolve(result).then((r) => { settled(); return r; }, (e) => { settled(); throw e; });
        };
      }
      if (window.XMLHttpRequest) {
        const nativeSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.send = function (...args) {
          inflight++; touch();
          this.addEventListener('loadend', settled, {once: true});
          return nativeSend.apply(this, args);
        };
      }
      // The drawn cursor's own moves are not the page's activity.
      const isCursorNode = (n) => !!(n && (n.nodeType === 1 ? n : n.parentElement)?.closest?.('[' + CURSOR_ATTR + ']'));
      const cursorOnly = (r) => {
        if (isCursorNode(r.target)) return true;
        const nodes = [...r.addedNodes, ...r.removedNodes];
        return r.type === 'childList' && nodes.length > 0 && nodes.every(isCursorNode);
      };
      new MutationObserver((records) => {
        if (records.some(r => !cursorOnly(r))) touch();
      }).observe(document, {subtree: true, childList: true, attributes: true, characterData: true});

      // Whether nothing has happened for `quietMs`: no request in flight,
      // and no DOM change or request completion in that time.
      const idle = (quietMs) => {
        const since = performance.now() - lastActivity;
        return {idle: inflight === 0 && since >= quietMs && document.readyState === 'complete', inflight, since: Math.round(since)};
      };

      const refFor = (el) => {
        let ref = elementToRef.get(el);
        if (!ref) {
          ref = 'e' + nextRef++;
          elementToRef.set(el, ref);
          refToElement.set(ref, new WeakRef(el));
        }
        return ref;
      };

      // A same-origin frame's document; null for a cross-origin one, which
      // page script cannot reach.
      const frameDocument = (el) => {
        if (el.tagName !== 'IFRAME' && el.tagName !== 'FRAME') return null;
        try { return el.contentDocument; } catch (e) { return null; }
      };

      // Every element, including inside open shadow roots and same-origin
      // frames.
      const allElements = () => {
        const out = [];
        const walk = (node) => {
          for (const el of node.querySelectorAll('*')) {
            out.push(el);
            if (el.shadowRoot) walk(el.shadowRoot);
            const inner = frameDocument(el);
            if (inner) walk(inner);
          }
        };
        walk(document);
        return out;
      };

      const queryAll = (selector) => {
        const out = [];
        const walk = (node) => {
          for (const el of node.querySelectorAll(selector)) out.push(el);
          for (const el of node.querySelectorAll('*')) {
            if (el.shadowRoot) walk(el.shadowRoot);
            const inner = frameDocument(el);
            if (inner) walk(inner);
          }
        };
        walk(document);
        return out;
      };

      // Where `el`'s frame puts its viewport, in this viewport's pixels.
      const frameOffset = (el) => {
        let x = 0, y = 0;
        let view = el.ownerDocument.defaultView;
        while (view && view !== window && view.frameElement) {
          const frame = view.frameElement;
          const r = frame.getBoundingClientRect();
          x += r.left + frame.clientLeft;
          y += r.top + frame.clientTop;
          view = frame.ownerDocument.defaultView;
        }
        return {x, y};
      };

      const rect = (el) => {
        const r = el.getBoundingClientRect();
        const o = frameOffset(el);
        return {left: r.left + o.x, top: r.top + o.y, width: r.width, height: r.height};
      };

      // Whether `inner` is `outer` or inside it, across shadow roots and
      // frames.
      const within = (inner, outer) => {
        for (let n = inner; n; n = n.parentNode || n.host || (n.defaultView && n.defaultView.frameElement) || null) {
          if (n === outer) return true;
        }
        return false;
      };

      // The innermost element at a point, into open shadow roots and
      // same-origin frames.
      const deepHit = (x, y) => {
        let el = document.elementFromPoint(x, y);
        for (;;) {
          if (el && el.shadowRoot) {
            const inner = el.shadowRoot.elementFromPoint(x, y);
            if (inner && inner !== el) { el = inner; continue; }
          }
          const doc = el && frameDocument(el);
          if (doc) {
            const r = el.getBoundingClientRect();
            x -= r.left + el.clientLeft;
            y -= r.top + el.clientTop;
            const inner = doc.elementFromPoint(x, y);
            if (inner) { el = inner; continue; }
          }
          return el;
        }
      };

      const visible = (el) => {
        if (el.closest('[' + CURSOR_ATTR + ']')) return false;
        if (el.checkVisibility && !el.checkVisibility({checkOpacity: true, checkVisibilityCSS: true})) return false;
        const r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0;
      };

      const clean = (s, max = 120) => {
        s = (s || '').replace(/\s+/g, ' ').trim();
        return s.length > max ? s.slice(0, max - 1) + '…' : s;
      };

      const isPassword = (el) =>
        !!el && el.tagName === 'INPUT' && (el.type || '').toLowerCase() === 'password';

      const INTERACTIVE = 'a[href], button, input:not([type=hidden]), select, textarea, summary, ' +
        '[role=button], [role=link], [role=menuitem], [role=menuitemcheckbox], [role=menuitemradio], ' +
        '[role=tab], [role=option], [role=checkbox], [role=radio], [role=switch], [role=combobox], ' +
        '[role=textbox], [role=searchbox], [role=treeitem], [role=gridcell], [role=row], ' +
        '[contenteditable=""], [contenteditable=true], [onclick], [tabindex]:not([tabindex="-1"])';

      const role = (el) => {
        const explicit = el.getAttribute('role');
        if (explicit) return explicit.split(' ')[0];
        const tag = el.tagName.toLowerCase();
        const type = (el.getAttribute('type') || '').toLowerCase();
        if (tag === 'a') return el.hasAttribute('href') ? 'link' : 'generic';
        if (tag === 'button' || tag === 'summary') return 'button';
        if (tag === 'select') return 'combobox';
        if (tag === 'textarea') return 'textbox';
        if (tag === 'input') {
          if (['button', 'submit', 'reset', 'image', 'file', 'color'].includes(type)) return 'button';
          if (type === 'checkbox') return 'checkbox';
          if (type === 'radio') return 'radio';
          if (type === 'range') return 'slider';
          if (type === 'search') return 'searchbox';
          return 'textbox';
        }
        if (/^h[1-6]$/.test(tag)) return 'heading';
        if (tag === 'td') return 'cell';
        if (tag === 'th') return 'columnheader';
        if (tag === 'tr') return 'row';
        if (tag === 'img') return 'img';
        if (el.isContentEditable) return 'textbox';
        return 'generic';
      };

      const name = (el) => {
        const label = el.getAttribute('aria-label');
        if (label) return clean(label);
        const labelledBy = el.getAttribute('aria-labelledby');
        if (labelledBy) {
          const text = labelledBy.split(/\s+/).map(id => el.ownerDocument.getElementById(id)?.innerText || '').join(' ');
          if (text.trim()) return clean(text);
        }
        if (el.labels && el.labels.length) {
          const text = Array.from(el.labels).map(l => l.innerText).join(' ');
          if (text.trim()) return clean(text);
        }
        if (el.tagName === 'IMG') return clean(el.alt || el.title);
        if (el.tagName === 'INPUT' && ['button', 'submit', 'reset'].includes((el.type || '').toLowerCase())) return clean(el.value);
        const text = el.innerText;
        if (text && text.trim()) return clean(text);
        return clean(el.getAttribute('placeholder') || el.title || el.getAttribute('name') || '');
      };

      const describe = (el) => {
        const r = rect(el);
        r.right = r.left + r.width;
        r.bottom = r.top + r.height;
        const tag = el.tagName.toLowerCase();
        const type = tag === 'input' ? (el.type || 'text').toLowerCase() : null;
        const out = {
          ref: refFor(el), role: role(el), name: name(el), tag, type,
          inViewport: r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth,
          x: Math.round(r.left), y: Math.round(r.top), width: Math.round(r.width), height: Math.round(r.height),
        };
        if (!isPassword(el) && (tag === 'input' || tag === 'textarea' || tag === 'select')) {
          if (type === 'checkbox' || type === 'radio') out.checked = el.checked;
          else out.value = clean(el.value, 300);
        }
        const ariaChecked = el.getAttribute('aria-checked');
        if (ariaChecked) out.checked = ariaChecked === 'true';
        if (el.disabled || el.getAttribute('aria-disabled') === 'true') out.disabled = true;
        // What a hover would show as a native tooltip, which the engine
        // draws outside the page and no screenshot captures.
        const title = el.title || el.closest('[title]')?.title;
        if (title && clean(title) !== out.name) out.title = clean(title, 300);
        const describedBy = el.getAttribute('aria-describedby');
        if (describedBy) {
          const text = describedBy.split(/\s+/).map(id => el.ownerDocument.getElementById(id)?.innerText || '').join(' ');
          if (text.trim()) out.description = clean(text, 300);
        }
        const shortcut = el.getAttribute('aria-keyshortcuts');
        if (shortcut) out.shortcut = clean(shortcut);
        return out;
      };

      const actionable = () => {
        const out = [];
        const seen = new Set();
        for (const el of allElements()) {
          if (seen.has(el) || !visible(el)) continue;
          let include = el.matches(INTERACTIVE) || /^H[1-6]$/.test(el.tagName);
          if (!include && getComputedStyle(el).cursor === 'pointer') {
            // A clickable thing the page built from plain elements; only its
            // outermost element counts.
            const parent = el.parentElement;
            include = !parent || getComputedStyle(parent).cursor !== 'pointer';
          }
          if (include) { seen.add(el); out.push(el); }
        }
        return out;
      };

      // How likely an element with matching text is what an agent means to
      // click: a real control first, then anything clickable the page built
      // from plain elements, then a heading, which often repeats a control's
      // text (a page titled after the menu item that opened it).
      const rank = (el) => {
        const r = role(el);
        if (r === 'heading') return 2;
        if (r === 'generic' || r === 'cell' || r === 'row' || r === 'gridcell') return 1;
        return 0;
      };
      const roleMatches = (el, wanted) => !wanted || role(el) === wanted;

      // The element a target means, with how many elements matched it: a
      // ref matches one; a selector or text can match several, and the
      // best-ranked one is taken.
      const resolveInfo = (target) => {
        if (!target) throw new Error('no target given');
        if (target.ref) {
          const el = refToElement.get(target.ref)?.deref();
          if (!el || !el.isConnected) throw new Error('no element ' + target.ref + ' on this page any more; take a new snapshot');
          return {el, matches: 1};
        }
        const forRole = target.role ? ' with role ' + target.role : '';
        if (target.selector) {
          const matches = queryAll(target.selector).filter(el => roleMatches(el, target.role));
          const el = matches.find(visible) || matches[0];
          if (!el) throw new Error('nothing matches selector ' + target.selector + forRole);
          return {el, matches: matches.length};
        }
        const wanted = target.text.toLowerCase();
        const candidates = actionable().filter(el => roleMatches(el, target.role));
        const byRank = (list) => list.sort((a, b) => rank(a) - rank(b));
        const exact = byRank(candidates.filter(el => name(el).toLowerCase() === wanted));
        if (exact.length) return {el: exact[0], matches: exact.length};
        const partial = byRank(candidates.filter(el => name(el).toLowerCase().includes(wanted)));
        if (partial.length) return {el: partial[0], matches: partial.length};
        // Any visible element whose own text is exactly that, smallest first.
        let best = null;
        let count = 0;
        for (const el of allElements()) {
          if (!visible(el) || !roleMatches(el, target.role) || clean(el.innerText, 10000).toLowerCase() !== wanted) continue;
          if (!best || best.contains(el)) best = el;
          count++;
        }
        if (!best) throw new Error('no visible element with text "' + target.text + '"' + forRole);
        return {el: best, matches: count};
      };

      const resolve = (target) => resolveInfo(target).el;

      // Scrolls `el` into the middle of the viewport and returns where to
      // click it, in CSS pixels from the viewport's top-left.
      const point = (el) => {
        el.scrollIntoView({block: 'center', inline: 'center', behavior: 'instant'});
        const r = rect(el);
        const x = Math.round(r.left + r.width / 2);
        const y = Math.round(r.top + r.height / 2);
        const hit = deepHit(x, y);
        // A hit on an ancestor (a label's padding, say) still lands on it.
        const obscured = !!hit && !within(hit, el) && !within(el, hit);
        return {x, y, obscured, element: describe(el), password: isPassword(el)};
      };

      const deepActive = () => {
        let el = document.activeElement;
        for (;;) {
          if (el && el.shadowRoot && el.shadowRoot.activeElement) { el = el.shadowRoot.activeElement; continue; }
          const doc = el && frameDocument(el);
          if (doc && doc.activeElement) { el = doc.activeElement; continue; }
          return el;
        }
      };

      // The text of the page and of each same-origin frame in it.
      const pageText = () => {
        const texts = [document.body ? document.body.innerText : ''];
        for (const el of queryAll('iframe, frame')) {
          const doc = frameDocument(el);
          if (doc && doc.body && visible(el)) texts.push(doc.body.innerText);
        }
        return texts.filter(t => t.trim()).join('\n');
      };

      const cursor = (x, y, pressed) => {
        let c = document.querySelector('[' + CURSOR_ATTR + ']');
        if (!c) {
          c = document.createElement('div');
          c.setAttribute(CURSOR_ATTR, '');
          c.style.cssText = 'position:fixed;left:0;top:0;width:24px;height:24px;z-index:2147483647;' +
            'pointer-events:none;transition:left .35s ease,top .35s ease,transform .12s ease;' +
            'transform-origin:3px 2px;';
          c.innerHTML = '<svg width="24" height="24" viewBox="0 0 24 24"><path d="M3 2l15 9.5-6.5 1.5 3.8 7.2-2.6 1.3-3.7-7.2L3 19z" ' +
            'fill="#111" stroke="#fff" stroke-width="1.5" stroke-linejoin="round"/></svg>';
          (document.body || document.documentElement).appendChild(c);
        }
        c.style.left = (x - 3) + 'px';
        c.style.top = (y - 2) + 'px';
        c.style.transform = pressed ? 'scale(0.85)' : 'scale(1)';
        if (pressed) {
          const ring = document.createElement('div');
          ring.setAttribute(CURSOR_ATTR, '');
          ring.style.cssText = 'position:fixed;width:36px;height:36px;margin:-18px 0 0 -18px;border-radius:50%;' +
            'border:3px solid rgba(10,132,255,.85);left:' + x + 'px;top:' + y + 'px;z-index:2147483646;' +
            'pointer-events:none;transition:transform .45s ease-out,opacity .45s ease-out;transform:scale(.3);';
          (document.body || document.documentElement).appendChild(ring);
          requestAnimationFrame(() => { ring.style.transform = 'scale(1.4)'; ring.style.opacity = '0'; });
          setTimeout(() => ring.remove(), 600);
        }
      };

      const snapshot = (maxText, maxElements) => {
        const text = pageText();
        const elements = actionable();
        return {
          url: location.href, title: document.title,
          text: text.length > maxText ? text.slice(0, maxText) : text,
          textTruncated: text.length > maxText,
          elements: elements.slice(0, maxElements).map(describe),
          elementsTruncated: elements.length > maxElements,
          viewportWidth: innerWidth, viewportHeight: innerHeight,
        };
      };

      const has = (selector, text) => {
        if (selector) return queryAll(selector).some(visible);
        return pageText().includes(text);
      };

      return {resolve, resolveInfo, point, describe, deepActive, isPassword, cursor, snapshot, has, visible, idle};
    })())
    """#
}
