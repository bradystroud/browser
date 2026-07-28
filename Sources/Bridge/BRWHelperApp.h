// Internal C++ interface -- never exposed to Swift.
#pragma once

#include "include/cef_app.h"
#include "include/cef_render_process_handler.h"
#include "include/wrapper/cef_message_router.h"

// CefApp for the Helper.app subprocesses (renderer/GPU/plugin/alerts --
// process_helper_mac.mm is one entry point shared by all of them; CEF
// determines the actual role from the command line at runtime and only
// calls the handler getter matching that role, so this being wrong for a
// non-renderer role is harmless -- GetRenderProcessHandler() is just never
// called there).
//
// This is deliberately a separate, minimal class from the browser process's
// BRWCefApp (see BRWEngine.mm), not a second role bolted onto it: BRWCefApp
// links against BRWMessagePump and (via BRWPageMessageRouter.mm)
// BRWClientHandler and everything *that* references -- content blocking,
// permissions, downloads, the works. None of that belongs in these small,
// sandboxed Helper.app binaries, whose only bridge-side responsibility is
// the renderer-side half of BRWPageMessageRouter's generic JS<->native
// channel (browser-ojh.1). Keeping it separate means the Helper targets
// only need to link this file, not the entire main-process bridge.
class BRWHelperApp : public CefApp, public CefRenderProcessHandler {
 public:
  BRWHelperApp();

  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override {
    return this;
  }

  // CefRenderProcessHandler methods -- forwarded to the renderer-side
  // CefMessageRouterRendererSide exactly as its own doc comments require of
  // the embedder. Constructed with BRWPageMessageRouter::Config() (an
  // inline, header-only function -- see that class's own doc comment for
  // why it has to be, specifically so this file doesn't need to link
  // BRWPageMessageRouter.mm/BRWClientHandler.mm) so both halves of the
  // channel agree on the query/cancel function names.
  void OnContextCreated(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefV8Context> context) override;
  void OnContextReleased(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefFrame> frame,
                         CefRefPtr<CefV8Context> context) override;
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override;

 private:
  CefRefPtr<CefMessageRouterRendererSide> renderer_side_router_;

  IMPLEMENT_REFCOUNTING(BRWHelperApp);
};
