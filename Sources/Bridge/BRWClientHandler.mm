#import "BRWClientHandler.h"

#include <vector>

#include "include/wrapper/cef_helpers.h"

namespace {
NSString* ToNSString(const CefString& s) {
  return [NSString stringWithUTF8String:s.ToString().c_str()];
}

// Every handler constructed but not yet OnBeforeClose'd. Only ever touched on
// the CEF UI thread (== main thread, given this app's single-threaded,
// external-message-pump CefSettings), so no locking is needed.
std::set<BRWClientHandler*>& Registry() {
  static std::set<BRWClientHandler*> registry;
  return registry;
}
}  // namespace

BRWClientHandler::BRWClientHandler(NSView* host_view) : host_view_(host_view) {
  Registry().insert(this);
}

void BRWClientHandler::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  browser_ = browser;

  if (pending_close_) {
    browser_->GetHost()->CloseBrowser(/*force_close=*/true);
    return;
  }

  // The CEF-created native view doesn't track our host view's size on its
  // own; give it standard AppKit autoresizing so window/pane resizes just work.
  NSView* cef_view = (__bridge NSView*)(void*)browser->GetHost()->GetWindowHandle();
  if (cef_view != nil && host_view_ != nil) {
    cef_view.frame = host_view_.bounds;
    cef_view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  }

  if (!pending_url_.empty()) {
    browser_->GetMainFrame()->LoadURL(pending_url_);
    pending_url_.clear();
  }
}

void BRWClientHandler::LoadURLWhenReady(const std::string& url) {
  if (browser_) {
    browser_->GetMainFrame()->LoadURL(url);
  } else {
    // CreateBrowser is asynchronous -- OnAfterCreated hasn't fired yet.
    // Remember the most recent request and flush it once it does, rather
    // than silently dropping a navigation requested in that window.
    pending_url_ = url;
  }
}

void BRWClientHandler::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  closed_ = true;
  browser_ = nullptr;
  Registry().erase(this);
}

// static
void BRWClientHandler::CloseAll() {
  CEF_REQUIRE_UI_THREAD();
  // Snapshot first -- CloseBrowser can synchronously reenter OnBeforeClose
  // for a browser that's already mid-teardown, which would mutate Registry()
  // out from under a live iterator.
  std::vector<BRWClientHandler*> handlers(Registry().begin(), Registry().end());
  for (BRWClientHandler* handler : handlers) {
    if (handler->closed_) {
      continue;
    }
    if (handler->browser_) {
      handler->browser_->GetHost()->CloseBrowser(/*force_close=*/true);
    } else {
      // OnAfterCreated hasn't fired yet -- flag it so it closes immediately
      // once CEF finishes creating the browser instead of loading a page.
      handler->pending_close_ = true;
    }
  }
}

// static
size_t BRWClientHandler::LiveCount() {
  return Registry().size();
}

void BRWClientHandler::OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                                              bool isLoading,
                                              bool canGoBack,
                                              bool canGoForward) {
  if (delegate_ && [delegate_ respondsToSelector:@selector(browserDidChangeLoadingState:canGoBack:canGoForward:)]) {
    [delegate_ browserDidChangeLoadingState:isLoading canGoBack:canGoBack canGoForward:canGoForward];
  }
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

void BRWClientHandler::OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) {
  if (delegate_ && [delegate_ respondsToSelector:@selector(browserDidChangeTitle:)]) {
    [delegate_ browserDidChangeTitle:ToNSString(title)];
  }
}

void BRWClientHandler::OnAddressChange(CefRefPtr<CefBrowser> browser,
                                         CefRefPtr<CefFrame> frame,
                                         const CefString& url) {
  // Only the main frame's URL is the tab's address; sub-frame navigations
  // (iframes, etc.) must not clobber the omnibox.
  if (!frame->IsMain()) {
    return;
  }
  if (delegate_ && [delegate_ respondsToSelector:@selector(browserDidChangeURL:)]) {
    [delegate_ browserDidChangeURL:ToNSString(url)];
  }
}

void BRWClientHandler::OnFaviconURLChange(CefRefPtr<CefBrowser> browser,
                                            const std::vector<CefString>& icon_urls) {
  if (!delegate_ || ![delegate_ respondsToSelector:@selector(browserDidChangeFaviconURL:)]) {
    return;
  }
  NSString* favicon = icon_urls.empty() ? nil : ToNSString(icon_urls.front());
  [delegate_ browserDidChangeFaviconURL:favicon];
}
