import Foundation
import WebKit

/// Per-tab audio mute for the WebKit engine. WKWebView has no public mute
/// API, so this is done from inside the page, best-effort.
///
/// How it works:
/// - A document-start script (`WebKitMuteScript.source`) runs in every frame,
///   cross-origin iframes included (`forMainFrameOnly: false`), from the
///   moment the tab is created. It has to run in the `.page` world: muting has
///   to reach media elements and AudioContexts the page creates, and those
///   exist only in that world. All of its state is closure-private, and it
///   keeps its own references to the builtins it uses, so page code cannot
///   read or change the mute state through a global.
/// - While muted, every `<audio>`/`<video>` has its real `muted` set to true.
///   That covers elements already in the document, elements added later
///   (MutationObserver), and detached `new Audio()` objects. Every element
///   that ever plays is remembered through a patched `play()` and a capturing
///   `play` listener, so a mute also reaches one that was already playing. The `muted` accessor is replaced:
///   while the tab is muted, the page's own writes are recorded instead of
///   applied, and reads return the page's own value. On unmute each element
///   gets back exactly the value the page last asked for. Because reads
///   return the page's value, AudioStateScript still sees a muted tab as
///   "audible" (the page *would* be making sound), which matches CEF, where
///   SetAudioMuted mutes below the page and the speaker indicator keeps
///   working.
/// - Web Audio: `AudioContext.prototype.destination` returns, for each
///   context, a GainNode wired to the real destination and dressed up as an
///   AudioDestinationNode. Its gain is 0 while muted and 1 otherwise, so
///   the context keeps running and its `currentTime` keeps advancing.
///   `OfflineAudioContext` is left alone because it never produces sound.
/// - Changing the state: the document-start script carries the tab's current
///   state as its initial value. Toggling swaps it for one with the new state,
///   which covers every later navigation and any new iframe. For documents
///   that are already loaded, a `postMessage` sent from the `.defaultClient`
///   world tells the main frame, and each frame forwards it to its own
///   children, which is how it reaches cross-origin iframes. The message
///   carries a random per-tab token and is swallowed by a capturing listener
///   registered before any page script, so page `message` handlers never see
///   it.
///
/// Limitations (what can still be heard):
/// - A page that sets out to evade the mute can do so. For example, it can
///   take pristine prototypes from a same-origin `about:blank` iframe it
///   creates and plays through synchronously, before the MutationObserver
///   sees that iframe. WebKit gives no guarantee that it injects into those
///   frames at all.
/// - A media element inside a shadow root that starts playing through
///   `autoplay`, rather than through `play()`, is missed. Neither
///   `querySelectorAll` nor the non-composed `play` event reaches it.
/// - AudioContexts whose `destination` a page captured before this script
///   ran. That cannot happen in a normal load, only in documents the script
///   never reached.
/// - Speech synthesis (`speechSynthesis.speak`) and anything the web process
///   plays outside media elements and Web Audio.
/// - If a toggle lands while a navigation is committing, the new document can
///   miss the message and start in the old state until the next toggle.
/// - Unmuting runs without a user gesture. WebKit's autoplay policy can pause
///   an element that was only allowed to autoplay because it was muted when
///   the page started it.
final class WebKitAudioMute {
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private var installedScript: WKUserScript?
    private var isMuted = false

    func install(into userContentController: WKUserContentController) {
        guard installedScript == nil else { return }
        let script = makeScript()
        userContentController.addUserScript(script)
        installedScript = script
    }

    func setMuted(_ muted: Bool, in webView: WKWebView) {
        let userContentController = webView.configuration.userContentController
        guard let old = installedScript else {
            // Only for a tab that was never given the document-start script.
            // Evaluating it now covers the current main-frame document. It
            // does not reach iframes, or AudioContexts created before this.
            isMuted = muted
            install(into: userContentController)
            webView.evaluateJavaScript(WebKitMuteScript.source(token: token, startMuted: muted), in: nil, in: .page) { _ in }
            return
        }
        guard muted != isMuted else { return }
        isMuted = muted

        // WKUserContentController cannot remove a single script. Rebuild the
        // list with ours swapped in place, so every other feature's scripts
        // keep their content worlds and injection order.
        let replacement = makeScript()
        let scripts = userContentController.userScripts.map { $0 === old ? replacement : $0 }
        userContentController.removeAllUserScripts()
        scripts.forEach(userContentController.addUserScript)
        installedScript = replacement

        webView.evaluateJavaScript(WebKitMuteScript.toggleMessage(token: token, muted: muted), in: nil, in: .defaultClient) { result in
            if case .failure(let error) = result {
                NSLog("Browser: WebKit mute toggle failed: %@", error.localizedDescription)
            }
        }
    }

    private func makeScript() -> WKUserScript {
        WKUserScript(source: WebKitMuteScript.source(token: token, startMuted: isMuted),
                     injectionTime: .atDocumentStart,
                     forMainFrameOnly: false,
                     in: .page)
    }
}

enum WebKitMuteScript {
    /// Run from the `.defaultClient` world, where `window.postMessage` is the
    /// untouched builtin. The main frame's hook receives it (event.source is
    /// the window itself) and forwards it to child frames.
    static func toggleMessage(token: String, muted: Bool) -> String {
        "window.postMessage({ brwMute: \(jsonString(token)), muted: \(muted) }, '*'); undefined;"
    }

    static func source(token: String, startMuted: Bool) -> String {
        "(\(body))(\(jsonString(token)), \(startMuted));"
    }

    private static func jsonString(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
        return String(data: data, encoding: .utf8) ?? "\"\""
    }

    static let body = """
    function (TOKEN, startMuted) {
      'use strict';
      var w = window;
      var apply = Reflect.apply;
      var getDesc = Object.getOwnPropertyDescriptor;
      var defProp = Object.defineProperty;
      var getProto = Object.getPrototypeOf;
      var setProto = Object.setPrototypeOf;
      var WM = WeakMap, wmGet = WM.prototype.get, wmSet = WM.prototype.set,
          wmHas = WM.prototype.has, wmDel = WM.prototype.delete;
      var St = Set, setAdd = St.prototype.add, setForEach = St.prototype.forEach, setClear = St.prototype.clear;
      var addListener = EventTarget.prototype.addEventListener;
      var dispatch = EventTarget.prototype.dispatchEvent;
      var stopImmediate = Event.prototype.stopImmediatePropagation;
      var Ev = Event;
      var docQsa = Document.prototype.querySelectorAll;
      var elQsa = Element.prototype.querySelectorAll;
      var nodeTypeGet = getDesc(Node.prototype, 'nodeType').get;
      var MO = w.MutationObserver, moObserve = MO.prototype.observe, moDisconnect = MO.prototype.disconnect;
      var WR = w.WeakRef, wrDeref = WR && WR.prototype.deref;
      var doc = document;
      var parentWin = w.parent;

      var muted = false;
      var pageMuted = new WM();
      var enforced = new St();
      var gainNodes = [];
      var played = [];
      var playedSeen = new WM();

      // Weak where possible: a wrapper the page has dropped is only still
      // reachable here if the element is playing, which keeps it alive.
      function remember(list, x) { list[list.length] = WR ? new WR(x) : x; }
      function forEachLive(list, f) {
        var live = [];
        for (var i = 0; i < list.length; i++) {
          var x = WR ? apply(wrDeref, list[i], []) : list[i];
          if (!x) { continue; }
          f(x);
          live[live.length] = list[i];
        }
        return live;
      }

      var MediaProto = w.HTMLMediaElement && w.HTMLMediaElement.prototype;
      var mutedDesc = MediaProto && getDesc(MediaProto, 'muted');
      function realGet(el) { return apply(mutedDesc.get, el, []); }
      function realSet(el, v) { apply(mutedDesc.set, el, [v]); }
      function isMedia(x) { try { realGet(x); return true; } catch (e) { return false; } }

      function enforce(el) {
        if (!apply(wmHas, pageMuted, [el])) {
          apply(wmSet, pageMuted, [el, realGet(el)]);
          apply(setAdd, enforced, [el]);
        }
        if (!realGet(el)) { realSet(el, true); }
      }

      function sweep(root) {
        var list = apply(root === doc ? docQsa : elQsa, root, ['audio, video']);
        for (var i = 0; i < list.length; i++) { enforce(list[i]); }
      }

      var observer = mutedDesc && new MO(function (records) {
        if (!muted) { return; }
        for (var i = 0; i < records.length; i++) {
          var added = records[i].addedNodes;
          for (var j = 0; j < added.length; j++) {
            var n = added[j];
            if (apply(nodeTypeGet, n, []) !== 1) { continue; }
            if (isMedia(n)) { enforce(n); } else { sweep(n); }
          }
        }
      });

      if (mutedDesc) {
        defProp(MediaProto, 'muted', {
          configurable: true,
          enumerable: mutedDesc.enumerable,
          get: function () {
            return apply(wmHas, pageMuted, [this]) ? apply(wmGet, pageMuted, [this]) : realGet(this);
          },
          set: function (v) {
            if (muted && isMedia(this)) {
              var wanted = !!v;
              var before = apply(wmHas, pageMuted, [this]) ? apply(wmGet, pageMuted, [this]) : realGet(this);
              apply(wmSet, pageMuted, [this, wanted]);
              apply(setAdd, enforced, [this]);
              if (!realGet(this)) { realSet(this, true); }
              if (before !== wanted) { apply(dispatch, this, [new Ev('volumechange')]); }
              return;
            }
            realSet(this, v);
          }
        });

        function notePlayed(el) {
          if (apply(wmHas, playedSeen, [el])) { return; }
          apply(wmSet, playedSeen, [el, true]);
          remember(played, el);
        }

        // Detached elements (new Audio()) are only reachable through
        // play(), so every element that ever plays is remembered, muted
        // or not, for a later mute to find.
        var origPlay = MediaProto.play;
        MediaProto.play = function play() {
          if (isMedia(this)) { notePlayed(this); if (muted) { enforce(this); } }
          return apply(origPlay, this, arguments);
        };

        apply(addListener, w, ['play', function (e) {
          if (isMedia(e.target)) { notePlayed(e.target); if (muted) { enforce(e.target); } }
        }, true]);
      }

      var gainValueSet = w.AudioParam && getDesc(w.AudioParam.prototype, 'value').set;
      var gainGet = w.GainNode && getDesc(w.GainNode.prototype, 'gain').get;
      function applyGain(node) { apply(gainValueSet, apply(gainGet, node, []), [muted ? 0 : 1]); }

      var patchedProtos = [];
      function patchContext(Ctor) {
        if (!Ctor || !w.GainNode || !w.AudioNode) { return; }
        var proto = Ctor.prototype;
        if (patchedProtos.indexOf(proto) !== -1) { return; }
        patchedProtos[patchedProtos.length] = proto;
        var p = proto, d;
        while (p && !(d = getDesc(p, 'destination'))) { p = getProto(p); }
        if (!d || !d.get) { return; }
        var createGain = proto.createGain;
        var connect = w.AudioNode.prototype.connect;
        var chanDesc = getDesc(w.AudioNode.prototype, 'channelCount');
        var ADN = w.AudioDestinationNode;
        var maxChanGet = ADN && getDesc(ADN.prototype, 'maxChannelCount').get;
        var byContext = new WM();
        defProp(proto, 'destination', {
          configurable: true,
          enumerable: d.enumerable,
          get: function () {
            var real = apply(d.get, this, []);
            var existing = apply(wmGet, byContext, [this]);
            if (existing) { return existing; }
            var node;
            try {
              node = apply(createGain, this, []);
              applyGain(node);
              apply(connect, node, [real]);
              if (ADN) { setProto(node, ADN.prototype); }
              if (maxChanGet) {
                defProp(node, 'maxChannelCount', { configurable: true, get: function () { return apply(maxChanGet, real, []); } });
              }
              defProp(node, 'channelCount', {
                configurable: true,
                get: function () { return apply(chanDesc.get, real, []); },
                set: function (v) { apply(chanDesc.set, real, [v]); apply(chanDesc.set, node, [v]); }
              });
            } catch (e) {
              return real;
            }
            apply(wmSet, byContext, [this, node]);
            remember(gainNodes, node);
            return node;
          }
        });
      }
      patchContext(w.AudioContext);
      patchContext(w.webkitAudioContext);

      function setMuted(m) {
        if (m === muted) { return; }
        muted = m;
        gainNodes = forEachLive(gainNodes, applyGain);
        if (!mutedDesc) { return; }
        if (m) {
          sweep(doc);
          played = forEachLive(played, enforce);
          apply(moObserve, observer, [doc, { childList: true, subtree: true }]);
        } else {
          apply(moDisconnect, observer, []);
          apply(setForEach, enforced, [function (el) {
            var v = apply(wmGet, pageMuted, [el]);
            apply(wmDel, pageMuted, [el]);
            if (realGet(el) !== v) { realSet(el, v); }
          }]);
          apply(setClear, enforced, []);
        }
      }

      function forward(m) {
        var n = 0;
        try { n = w.length; } catch (e) {}
        for (var i = 0; i < n; i++) {
          try { w[i].postMessage({ brwMute: TOKEN, muted: m }, '*'); } catch (e) {}
        }
      }

      apply(addListener, w, ['message', function (e) {
        var data;
        try { data = e.data; } catch (x) { return; }
        if (!data || typeof data !== 'object' || data.brwMute !== TOKEN) { return; }
        apply(stopImmediate, e, []);
        if (e.source !== w && e.source !== parentWin) { return; }
        var m = data.muted === true;
        setMuted(m);
        forward(m);
      }, true]);

      if (startMuted) { setMuted(true); }
    }
    """
}
