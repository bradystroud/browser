// Internal C++ interface -- never exposed to Swift.
//
// One tab's agent-control channel: DevTools protocol commands sent to that
// tab's own browser with CefBrowserHost::ExecuteDevToolsMethod, and their
// results and events read back through a CefDevToolsMessageObserver. The
// session is the inspected browser's own, so the channel can only ever reach
// the one tab it belongs to, never another tab or the browser target.
//
// It shares that session with an open DevTools front-end (BRWDevToolsHandler)
// and with responsive design mode. Its ids live in their own range below the
// front-end's offset, so BRWDevToolsHandler leaves its results alone.
#pragma once

#import <Foundation/Foundation.h>

#include <map>

#include "include/cef_browser.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_registration.h"

class BRWAutomationChannel : public CefDevToolsMessageObserver {
 public:
  using Completion = void (^)(BOOL success, NSString* resultJSON);
  using EventHandler = void (^)(NSString* method, NSString* paramsJSON);

  BRWAutomationChannel() = default;

  // Sends `method` with `params_json` (a JSON object, or empty for none) to
  // `browser`. `completion` runs on the main thread exactly once: with the
  // result object, or with NO and the error object (or a short message) when
  // the command fails, the agent detaches, or the channel is closed.
  void Execute(CefRefPtr<CefBrowser> browser,
               const std::string& method,
               const std::string& params_json,
               Completion completion);

  void SetEventHandler(EventHandler handler);

  // Fails every pending command and stops listening. Safe to call repeatedly.
  void Close();

  // CefDevToolsMessageObserver methods:
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser,
                              int message_id,
                              bool success,
                              const void* result,
                              size_t result_size) override;
  void OnDevToolsEvent(CefRefPtr<CefBrowser> browser,
                       const CefString& method,
                       const void* params,
                       size_t params_size) override;
  void OnDevToolsAgentDetached(CefRefPtr<CefBrowser> browser) override;

 private:
  void FailAll(NSString* reason);

  CefRefPtr<CefRegistration> registration_;
  int registered_browser_id_ = 0;
  std::map<int, Completion> pending_;
  EventHandler event_handler_ = nil;

  IMPLEMENT_REFCOUNTING(BRWAutomationChannel);
};
