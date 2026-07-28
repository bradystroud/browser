// Internal C++ interface -- never exposed to Swift.
#pragma once

#include <memory>
#include <string>

#include "include/wrapper/cef_message_router.h"

// Process-wide, generic JS<->native message channel: a page calls
// `window.cefQuery({request, onSuccess, onFailure})`, forwarded here to
// whichever BRWClientHandler owns the originating browser (via
// BRWClientHandler::ForBrowser), then eventually answered via
// -[BRWBrowser respondToPageMessageWithId:success:response:] (which calls
// Respond() below). Deliberately reusable, not password-specific --
// browser-ojh.1's password-manager form-detection/save-prompt flow is the
// first user, but any future feature needing a JS->native round trip (as
// opposed to executeJavaScript's fire-and-forget, or getPageSource's
// single-shot HTML snapshot) can share this same channel; dispatch on the
// `request` string's own content (e.g. a JSON payload with a "type" field)
// to tell separate features' messages apart on the Swift side.
//
// One instance for the whole browser process (see Get()) wraps
// CefMessageRouterBrowserSide -- the renderer-side half
// (CefMessageRouterRendererSide) is a separate object owned by
// BRWHelperApp, since it must run in the renderer process, not here; both
// must be constructed with the exact same CefMessageRouterConfig (see
// Config()). Config() is defined inline right here (rather than out-of-line
// in BRWPageMessageRouter.mm) specifically so BRWHelperApp -- which lives in
// the small Helper.app subprocess target and must NOT link the rest of this
// file's .mm (that would drag in BRWClientHandler and everything it
// references, none of which the renderer helper needs) -- can call it by
// including only this header.
class BRWPageMessageRouter {
 public:
  static BRWPageMessageRouter& Get();

  // Shared by the renderer-side router in BRWHelperApp -- see this class's
  // own doc comment for why both sides must agree on this.
  static CefMessageRouterConfig Config() {
    CefMessageRouterConfig config;
    config.js_query_function = "cefQuery";
    config.js_cancel_function = "cefQueryCancel";
    return config;
  }

  // The below methods should be called from BRWClientHandler's own matching
  // CEF callbacks, exactly as CefMessageRouterBrowserSide's own doc
  // comments require of its caller.
  void OnBeforeClose(CefRefPtr<CefBrowser> browser);
  void OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame);
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser);
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                 CefRefPtr<CefFrame> frame,
                                 CefProcessId source_process,
                                 CefRefPtr<CefProcessMessage> message);

  // Completes a pending query previously delivered via
  // -browserDidReceivePageMessage:requestId: on some BRWBrowserDelegate.
  // No-op if `requestId` isn't currently pending (e.g. the page navigated
  // away and CEF already canceled it internally).
  void Respond(int64_t requestId, bool success, const std::string& response);

 private:
  BRWPageMessageRouter();
  BRWPageMessageRouter(const BRWPageMessageRouter&) = delete;
  BRWPageMessageRouter& operator=(const BRWPageMessageRouter&) = delete;

  CefRefPtr<CefMessageRouterBrowserSide> router_;

  class HandlerImpl;
  std::unique_ptr<HandlerImpl> handler_;
};
