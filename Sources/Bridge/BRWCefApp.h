// Internal C++ interface -- never exposed to Swift.
#pragma once

#include "include/cef_app.h"

// Application-level (browser-process) callbacks. Browsers are created on
// demand by BRWEngine/BRWBrowser rather than eagerly in
// OnContextInitialized(), since CEF is initialized once up front but the
// Swift side decides when/where to create each browser surface.
//
// This is the browser process's CefApp (constructed once, in BRWEngine.mm)
// -- the Helper.app subprocesses (renderer/GPU/plugin/alerts) use their own,
// much smaller BRWHelperApp instead (see process_helper_mac.mm and that
// class's own doc comment for why they're kept separate).
class BRWCefApp : public CefApp, public CefBrowserProcessHandler {
 public:
  BRWCefApp();

  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }

  void OnBeforeCommandLineProcessing(
      const CefString& process_type,
      CefRefPtr<CefCommandLine> command_line) override;

  void OnScheduleMessagePumpWork(int64_t delay_ms) override;

 private:
  IMPLEMENT_REFCOUNTING(BRWCefApp);
};
