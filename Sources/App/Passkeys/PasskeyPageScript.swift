import Foundation

/// Document-start script for CEF tabs that sends `navigator.credentials`
/// passkey calls to the system's own passkey sheet (Touch ID, iCloud
/// Keychain, a phone, a security key) through `PlatformPasskeyBroker`.
///
/// Chromium has this sheet but cannot show it here: it finds the tab's
/// window through a `views::Widget`, which an Alloy browser parented into an
/// AppKit view does not have, so it falls back to QR codes and security keys
/// with no error (see the Passkeys note in AGENTS.md). WebKit tabs never get
/// this script, because WebKit reaches the same sheet by itself.
///
/// The page cannot widen what it may do through this script: the broker takes
/// the origin from the engine, not from the message, and checks the RP ID
/// against it (`WebAuthnPlanner`). Anything the broker does not take -- a
/// request it answers with `fallback`, a non-`publicKey` credential, a call
/// from a subframe, which never gets this script -- goes to Chromium's own
/// implementation, exactly as before.
///
/// The objects handed back are plain objects whose prototypes are the real
/// `PublicKeyCredential` / `Authenticator*Response` prototypes, so
/// `instanceof` checks pass; every field is an own property, which shadows
/// the prototype's native getters (those would throw on an object Chromium
/// did not make).
enum PasskeyPageScript {
    static let source = #"""
    (function () {
      if (window.__brwPasskeys) { return; }
      window.__brwPasskeys = true;
      if (!window.isSecureContext || !navigator.credentials || !window.PublicKeyCredential ||
          typeof window.cefQuery !== 'function') { return; }

      var credentials = navigator.credentials;
      var realGet = credentials.get.bind(credentials);
      var realCreate = credentials.create.bind(credentials);
      var nextToken = 1;

      function bytes(source) {
        if (source instanceof ArrayBuffer) { return new Uint8Array(source); }
        if (ArrayBuffer.isView(source)) { return new Uint8Array(source.buffer, source.byteOffset, source.byteLength); }
        throw new TypeError('Expected a BufferSource.');
      }
      function b64(source) {
        var view = bytes(source), text = '';
        for (var i = 0; i < view.length; i++) { text += String.fromCharCode(view[i]); }
        return btoa(text).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
      }
      function unb64(text) {
        var raw = atob(text.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((text.length + 3) % 4));
        var out = new Uint8Array(raw.length);
        for (var i = 0; i < raw.length; i++) { out[i] = raw.charCodeAt(i); }
        return out.buffer;
      }
      function descriptors(list) {
        if (!list) { return undefined; }
        return Array.prototype.map.call(list, function (d) {
          return { id: b64(d.id), type: d.type, transports: d.transports ? Array.prototype.slice.call(d.transports) : undefined };
        });
      }
      function encodeGet(o) {
        return {
          challenge: b64(o.challenge), rpId: o.rpId, timeout: o.timeout,
          userVerification: o.userVerification, allowCredentials: descriptors(o.allowCredentials)
        };
      }
      function encodeCreate(o) {
        var rp = o.rp || {}, user = o.user || {}, sel = o.authenticatorSelection;
        return {
          challenge: b64(o.challenge),
          rp: { id: rp.id, name: rp.name },
          user: { id: b64(user.id), name: user.name, displayName: user.displayName },
          pubKeyCredParams: o.pubKeyCredParams ? Array.prototype.map.call(o.pubKeyCredParams, function (p) {
            return { type: p.type, alg: p.alg };
          }) : undefined,
          timeout: o.timeout,
          excludeCredentials: descriptors(o.excludeCredentials),
          authenticatorSelection: sel ? {
            authenticatorAttachment: sel.authenticatorAttachment, residentKey: sel.residentKey,
            requireResidentKey: sel.requireResidentKey, userVerification: sel.userVerification
          } : undefined,
          attestation: o.attestation,
          extensions: o.extensions ? { credProps: !!o.extensions.credProps } : undefined
        };
      }

      function send(payload) {
        return new Promise(function (resolve, reject) {
          window.cefQuery({
            request: JSON.stringify(payload),
            onSuccess: function (response) { resolve(response ? JSON.parse(response) : {}); },
            onFailure: function (code, message) {
              var error = { name: 'NotAllowedError', message: 'The operation either timed out or was not allowed.' };
              try { if (message) { error = JSON.parse(message); } } catch (e) {}
              reject(error.name === 'TypeError' ? new TypeError(error.message) : new DOMException(error.message, error.name));
            }
          });
        });
      }

      function own(target, values) {
        Object.keys(values).forEach(function (key) {
          Object.defineProperty(target, key, { value: values[key], enumerable: true, configurable: true });
        });
        return target;
      }

      function credential(result, isCreate) {
        var r = result.response, response, json;
        if (isCreate) {
          response = Object.create(AuthenticatorAttestationResponse.prototype);
          var transports = (r.transports || []).slice();
          var publicKey = r.publicKey ? unb64(r.publicKey) : null;
          own(response, {
            clientDataJSON: unb64(r.clientDataJSON),
            attestationObject: unb64(r.attestationObject),
            getTransports: function () { return transports.slice(); },
            getAuthenticatorData: function () { return unb64(r.authenticatorData); },
            getPublicKey: function () { return publicKey ? publicKey.slice(0) : null; },
            getPublicKeyAlgorithm: function () { return r.publicKeyAlgorithm; }
          });
          json = {
            clientDataJSON: r.clientDataJSON, attestationObject: r.attestationObject,
            authenticatorData: r.authenticatorData, transports: transports,
            publicKeyAlgorithm: r.publicKeyAlgorithm
          };
          if (r.publicKey) { json.publicKey = r.publicKey; }
        } else {
          response = Object.create(AuthenticatorAssertionResponse.prototype);
          own(response, {
            clientDataJSON: unb64(r.clientDataJSON),
            authenticatorData: unb64(r.authenticatorData),
            signature: unb64(r.signature),
            userHandle: r.userHandle ? unb64(r.userHandle) : null
          });
          json = {
            clientDataJSON: r.clientDataJSON, authenticatorData: r.authenticatorData,
            signature: r.signature
          };
          if (r.userHandle) { json.userHandle = r.userHandle; }
        }
        var extensions = result.clientExtensionResults || {};
        var made = Object.create(PublicKeyCredential.prototype);
        return own(made, {
          id: result.id,
          rawId: unb64(result.id),
          type: 'public-key',
          response: response,
          authenticatorAttachment: result.authenticatorAttachment || null,
          getClientExtensionResults: function () { return JSON.parse(JSON.stringify(extensions)); },
          toJSON: function () {
            return {
              id: result.id, rawId: result.id, type: 'public-key',
              authenticatorAttachment: result.authenticatorAttachment || null,
              clientExtensionResults: JSON.parse(JSON.stringify(extensions)),
              response: json
            };
          }
        });
      }

      function run(kind, options, real) {
        var publicKey = options && options.publicKey;
        if (!publicKey) { return real(options); }
        var signal = options.signal;
        if (signal && signal.aborted) {
          return Promise.reject(signal.reason !== undefined ? signal.reason : new DOMException('The operation was aborted.', 'AbortError'));
        }
        var payload;
        try {
          payload = {
            type: kind === 'create' ? 'webauthnCreate' : 'webauthnGet',
            requestToken: String(nextToken++),
            mediation: options.mediation,
            publicKey: kind === 'create' ? encodeCreate(publicKey) : encodeGet(publicKey)
          };
        } catch (e) {
          return Promise.reject(e);
        }
        // An option this script does not model goes to Chromium unchanged.
        if (publicKey.extensions && Object.keys(publicKey.extensions).some(function (k) { return k !== 'credProps'; })) {
          return real(options);
        }
        if (options.mediation !== 'conditional' && !document.hasFocus()) {
          return Promise.reject(new DOMException('The document is not focused.', 'NotAllowedError'));
        }
        return new Promise(function (resolve, reject) {
          var settled = false;
          function onAbort() {
            if (settled) { return; }
            settled = true;
            send({ type: 'webauthnCancel', requestToken: payload.requestToken }).catch(function () {});
            reject(signal.reason !== undefined ? signal.reason : new DOMException('The operation was aborted.', 'AbortError'));
          }
          if (signal) { signal.addEventListener('abort', onAbort, { once: true }); }
          send(payload).then(function (result) {
            if (settled) { return; }
            settled = true;
            if (signal) { signal.removeEventListener('abort', onAbort); }
            if (result.fallback) {
              real(options).then(resolve, reject);
            } else {
              resolve(credential(result, kind === 'create'));
            }
          }, function (error) {
            if (settled) { return; }
            settled = true;
            if (signal) { signal.removeEventListener('abort', onAbort); }
            reject(error);
          });
        });
      }

      credentials.get = function get(options) { return run('get', options, realGet); };
      credentials.create = function create(options) { return run('create', options, realCreate); };

      // The system sheet always offers this Mac's passkeys. It has no
      // autofill (conditional) UI for a page, so sites are told to show a
      // button instead.
      PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = function () { return Promise.resolve(true); };
      PublicKeyCredential.isConditionalMediationAvailable = function () { return Promise.resolve(false); };
      if (typeof PublicKeyCredential.getClientCapabilities === 'function') {
        var realCapabilities = PublicKeyCredential.getClientCapabilities.bind(PublicKeyCredential);
        PublicKeyCredential.getClientCapabilities = function () {
          return realCapabilities().catch(function () { return {}; }).then(function (caps) {
            return Object.assign({}, caps, {
              conditionalGet: false, conditionalCreate: false, hybridTransport: true,
              passkeyPlatformAuthenticator: true, userVerifyingPlatformAuthenticator: true
            });
          });
        };
      }
    })();
    """#
}
