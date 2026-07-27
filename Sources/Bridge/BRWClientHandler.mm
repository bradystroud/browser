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
    pending_close_ = false;
    RequestClose();
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

void BRWClientHandler::RequestClose() {
  CEF_REQUIRE_UI_THREAD();
  if (closed_ || close_requested_) {
    return;
  }
  if (!browser_) {
    // OnAfterCreated hasn't fired yet -- flag it so it closes immediately
    // once CEF finishes creating the browser instead of loading a page.
    pending_close_ = true;
    return;
  }
  close_requested_ = true;

  // CEF's Alloy/SetAsChild close-detection on macOS appears to depend on the
  // browser-created native view actually being removed from the AppKit view
  // hierarchy -- without this, CloseBrowser() completes without error but
  // OnBeforeClose is never delivered, hanging shutdown forever (confirmed:
  // message pump ticking correctly, LiveCount() stuck > 0). Not documented
  // in CEF's own header, but matches an identical report from another
  // Swift+CEF project: github.com/lvsti/CEF.swift/issues/22.
  NSView *cef_view = (__bridge NSView *)(void *)browser_->GetHost()->GetWindowHandle();
  [cef_view removeFromSuperview];

  browser_->GetHost()->CloseBrowser(/*force_close=*/true);
}

// static
void BRWClientHandler::CloseAll() {
  CEF_REQUIRE_UI_THREAD();
  // Snapshot first -- CloseBrowser can synchronously reenter OnBeforeClose
  // for a browser that's already mid-teardown, which would mutate Registry()
  // out from under a live iterator.
  std::vector<BRWClientHandler*> handlers(Registry().begin(), Registry().end());
  for (BRWClientHandler* handler : handlers) {
    handler->RequestClose();
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
                                  int httpStatusCode) {
  // Only the main frame's completed load is a "visit" worth recording --
  // iframe/subresource loads finish here too but aren't navigations the
  // history UI should ever show. OnLoadError (with ERR_ABORTED filtered out
  // below) is the failure counterpart; a load that ends up here genuinely
  // committed.
  if (!frame->IsMain()) {
    return;
  }
  if (delegate_ && [delegate_ respondsToSelector:@selector(browserDidCommitNavigation:)]) {
    [delegate_ browserDidCommitNavigation:ToNSString(frame->GetURL())];
  }
}

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

namespace {
// Finder/Safari-style de-duplication: "name.ext", then "name (1).ext",
// "name (2).ext", ... -- so a second download of the same filename to
// ~/Downloads never silently overwrites the first.
NSString* UniqueDownloadPath(NSString* directory, NSString* suggested_name) {
  NSFileManager* fm = [NSFileManager defaultManager];
  NSString* candidate = [directory stringByAppendingPathComponent:suggested_name];
  if (![fm fileExistsAtPath:candidate]) {
    return candidate;
  }

  NSString* extension = [suggested_name pathExtension];
  NSString* base = [suggested_name stringByDeletingPathExtension];
  for (int i = 1; i < 10000; ++i) {
    NSString* attempt = extension.length > 0
        ? [NSString stringWithFormat:@"%@ (%d).%@", base, i, extension]
        : [NSString stringWithFormat:@"%@ (%d)", base, i];
    candidate = [directory stringByAppendingPathComponent:attempt];
    if (![fm fileExistsAtPath:candidate]) {
      return candidate;
    }
  }
  return candidate;  // Effectively unreachable; last attempt wins over an infinite loop.
}
}  // namespace

bool BRWClientHandler::OnBeforeDownload(CefRefPtr<CefBrowser> browser,
                                         CefRefPtr<CefDownloadItem> download_item,
                                         const CefString& suggested_name,
                                         CefRefPtr<CefBeforeDownloadCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  NSString* downloads_dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Downloads"];
  [[NSFileManager defaultManager] createDirectoryAtPath:downloads_dir
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
  NSString* suggested = ToNSString(suggested_name);
  NSString* path = UniqueDownloadPath(downloads_dir, suggested);

  // false = no save dialog, per the plan's M3 scope ("default to ~/Downloads,
  // no save-dialog for now").
  callback->Continue([path UTF8String], false);

  if (delegate_ && [delegate_ respondsToSelector:@selector(browserDidBeginDownloadWithId:url:suggestedName:destinationPath:)]) {
    [delegate_ browserDidBeginDownloadWithId:download_item->GetId()
                                          url:ToNSString(download_item->GetURL())
                                suggestedName:suggested
                              destinationPath:path];
  }
  return true;  // Proceed with the download (return false would cancel it).
}

void BRWClientHandler::OnDownloadUpdated(CefRefPtr<CefBrowser> browser,
                                          CefRefPtr<CefDownloadItem> download_item,
                                          CefRefPtr<CefDownloadItemCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  if (!delegate_ || ![delegate_ respondsToSelector:@selector(browserDidUpdateDownloadWithId:receivedBytes:totalBytes:isComplete:isCancelled:isInterrupted:)]) {
    return;
  }
  [delegate_ browserDidUpdateDownloadWithId:download_item->GetId()
                               receivedBytes:download_item->GetReceivedBytes()
                                  totalBytes:download_item->GetTotalBytes()
                                  isComplete:download_item->IsComplete()
                                 isCancelled:download_item->IsCanceled()
                               isInterrupted:download_item->IsInterrupted()];
}
