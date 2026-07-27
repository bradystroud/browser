#import "BRWClientHandler.h"

#include "include/wrapper/cef_helpers.h"

BRWClientHandler::BRWClientHandler(NSView* host_view) : host_view_(host_view) {}

void BRWClientHandler::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  browser_ = browser;

  // The CEF-created native view doesn't track our host view's size on its
  // own; give it standard AppKit autoresizing so window/pane resizes just work.
  NSView* cef_view = (__bridge NSView*)(void*)browser->GetHost()->GetWindowHandle();
  if (cef_view != nil && host_view_ != nil) {
    cef_view.frame = host_view_.bounds;
    cef_view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  }
}

void BRWClientHandler::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  closed_ = true;
  browser_ = nullptr;
}

void BRWClientHandler::OnLoadEnd(CefRefPtr<CefBrowser> browser,
                                  CefRefPtr<CefFrame> frame,
                                  int httpStatusCode) {}

void BRWClientHandler::OnLoadError(CefRefPtr<CefBrowser> browser,
                                     CefRefPtr<CefFrame> frame,
                                     ErrorCode errorCode,
                                     const CefString& errorText,
                                     const CefString& failedUrl) {
  // CEF_ERRORCODE_ABORTED (user navigated away before the load finished) is
  // routine, not a real failure -- e.g. every navigation the address bar
  // replaces triggers one for the previous in-flight load.
  if (errorCode == ERR_ABORTED) {
    return;
  }
  NSLog(@"Browser: load failed for %s: %s (code %d)", failedUrl.ToString().c_str(),
        errorText.ToString().c_str(), errorCode);
}
