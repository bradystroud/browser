// Internal C++ interface -- never exposed to Swift.
#pragma once

#import <AppKit/AppKit.h>

#include "include/cef_client.h"

// Per-browser callbacks. One instance per BRWBrowser. Owns a reference to the
// NSView the browser is parented into so it can make the CEF-created native
// view track that host view's size via ordinary AppKit autoresizing, instead
// of hand-rolling resize-notification plumbing.
class BRWClientHandler : public CefClient,
                         public CefLifeSpanHandler,
                         public CefLoadHandler {
 public:
  explicit BRWClientHandler(NSView* host_view);

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }

  // CefLifeSpanHandler methods:
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;

  // CefLoadHandler methods:
  void OnLoadEnd(CefRefPtr<CefBrowser> browser,
                 CefRefPtr<CefFrame> frame,
                 int httpStatusCode) override;
  void OnLoadError(CefRefPtr<CefBrowser> browser,
                    CefRefPtr<CefFrame> frame,
                    ErrorCode errorCode,
                    const CefString& errorText,
                    const CefString& failedUrl) override;

  CefRefPtr<CefBrowser> GetBrowser() { return browser_; }
  bool IsClosed() const { return closed_; }

 private:
  NSView* host_view_;
  CefRefPtr<CefBrowser> browser_;
  bool closed_ = false;

  IMPLEMENT_REFCOUNTING(BRWClientHandler);
};
