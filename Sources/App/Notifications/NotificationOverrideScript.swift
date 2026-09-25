import Foundation

/// Document-start script (browser-7jz.3) that overrides `window.Notification`
/// with a thin shim forwarding to native macOS notifications, via the
/// existing generic `window.cefQuery` channel (PageMessageDispatcher) --
/// deliberately not a second, parallel channel (see WebPushCoordinator's own
/// doc comment for why: three features already collided over
/// Tab.onPageMessage earlier this session before PageMessageDispatcher
/// existed to arbitrate it).
///
/// Why override window.Notification at all, rather than relying on
/// Chromium's own real, compiled-in Notification implementation: CEF's
/// public embedder API has no callback whatsoever for "a page's
/// Notification API asked to show a notification" (grepped Notification/
/// PushSubscription/ServiceWorker/BackgroundSync across every public CEF
/// header -- nothing but incidental doc-comment mentions and one unrelated
/// content-settings-type enum value). Chromium's real implementation
/// happily constructs the notification and correctly gates it on
/// permission via CefPermissionHandler (browser-12m.2, already built) --
/// there's just no way for this app to ever find out it happened, so
/// nothing would ever reach macOS's actual Notification Center without
/// this shim.
///
/// Permission is deliberately NEVER reimplemented here: `permission` and
/// `requestPermission()` both delegate straight to the REAL, saved
/// Notification's own implementations, so the existing per-origin
/// permission flow (browser-12m.2's CefPermissionHandler ->
/// PermissionPromptController -> PermissionStore, already correctly
/// wired and already respecting a remembered per-(profile, origin)
/// decision) is the only thing that ever decides whether a notification
/// is allowed -- this script only ever decides whether a *granted*
/// notification actually gets shown to the user.
///
/// The one exception is narrowing: after Chromium answers "granted", the
/// shim asks the native side ("notificationPermission") as well, and reports
/// "denied" when WebPushCoordinator would refuse to show anything -- a
/// private window, or a site with no stored grant. The native check is the
/// real gate either way; this only keeps what the page is told consistent
/// with it.
///
/// Only the *foreground* Notification API is covered -- pages/service
/// workers that are actually running right now. Full background Web Push
/// (delivery while the browser process itself isn't running) needs
/// ServiceWorker/PushSubscription/BackgroundSync hooks CEF's public API
/// doesn't expose at all, so it isn't realistically buildable against
/// this embedder.
enum NotificationOverrideScript {
    static let source = """
    (function() {
      if (window.__brwNotificationOverride) { return; }
      window.__brwNotificationOverride = true;

      var RealNotification = window.Notification;
      if (!RealNotification) { return; }

      function send(payload) {
        return new Promise(function(resolve, reject) {
          try {
            window.cefQuery({
              request: JSON.stringify(payload),
              onSuccess: function(response) {
                var parsed;
                try { parsed = JSON.parse(response || '{}'); } catch (e) { parsed = {}; }
                resolve(parsed);
              },
              onFailure: function() { reject(new Error('notification bridge failed')); }
            });
          } catch (e) {
            reject(e);
          }
        });
      }

      // Last native answer, so the synchronous `permission` getter can
      // report a native refusal Chromium itself does not know about.
      var nativeDenied = false;
      function requestPermission() {
        return RealNotification.requestPermission().then(function(permission) {
          if (permission !== 'granted') { return permission; }
          return send({ type: 'notificationPermission' }).then(function(result) {
            var granted = !!result && result.permission === 'granted';
            nativeDenied = !granted;
            return granted ? 'granted' : 'denied';
          }, function() {
            nativeDenied = true;
            return 'denied';
          });
        });
      }

      function BRWNotification(title, options) {
        var self = this;
        options = options || {};
        this.title = title;
        this.body = options.body || '';
        this.icon = options.icon || '';
        this.tag = options.tag || '';
        this.data = options.data;
        this.onclick = null;
        this.onclose = null;
        this.onerror = null;
        this.onshow = null;
        this._listeners = {};
        this._closed = false;
        this._id = null;

        requestPermission().then(function(permission) {
          if (permission !== 'granted' || self._closed) { return; }
          return send({
            type: 'notificationShow', title: title, body: self.body, icon: self.icon, tag: self.tag
          }).then(function(result) {
            if (self._closed || !result || !result.id) { return; }
            self._id = result.id;
            self._fire('show');
            send({ type: 'notificationWaitForEvent', id: result.id }).then(function(eventResult) {
              self._fire((eventResult && eventResult.event === 'click') ? 'click' : 'close');
            }).catch(function() {});
          });
        }).catch(function() {
          self._fire('error');
        });
      }

      BRWNotification.prototype._fire = function(name) {
        var handler = this['on' + name];
        if (typeof handler === 'function') {
          try { handler.call(this, new Event(name)); } catch (e) {}
        }
        var list = this._listeners[name];
        if (list) {
          list.slice().forEach(function(fn) {
            try { fn.call(this, new Event(name)); } catch (e) {}
          }, this);
        }
      };

      BRWNotification.prototype.addEventListener = function(name, fn) {
        if (!this._listeners[name]) { this._listeners[name] = []; }
        this._listeners[name].push(fn);
      };

      BRWNotification.prototype.removeEventListener = function(name, fn) {
        var list = this._listeners[name];
        if (!list) { return; }
        var index = list.indexOf(fn);
        if (index !== -1) { list.splice(index, 1); }
      };

      BRWNotification.prototype.close = function() {
        if (this._closed) { return; }
        this._closed = true;
        if (this._id) {
          send({ type: 'notificationClose', id: this._id }).catch(function() {});
        }
      };

      Object.defineProperty(BRWNotification, 'permission', {
        get: function() { return nativeDenied ? 'denied' : RealNotification.permission; }
      });
      BRWNotification.requestPermission = function(callback) {
        var promise = requestPermission();
        if (typeof callback === 'function') { promise.then(callback); }
        return promise;
      };

      window.Notification = BRWNotification;
    })();
    """
}
