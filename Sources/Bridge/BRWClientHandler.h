// Internal C++ interface -- never exposed to Swift.
#pragma once

#import <AppKit/AppKit.h>

#include <set>
#include <string>

#include "include/cef_client.h"
#include "include/cef_display_handler.h"
#include "include/cef_download_handler.h"
#include "include/cef_download_item.h"

#import "BRWBrowser.h"  // for the BRWBrowserDelegate protocol only.

// Per-browser callbacks. One instance per BRWBrowser. Owns a reference to the
// NSView the browser is parented into so it can make the CEF-created native
// view track that host view's size via ordinary AppKit autoresizing, instead
// of hand-rolling resize-notification plumbing. Also forwards title/URL/
// favicon/loading-state/navigation-commit/download changes to the
// BRWBrowserDelegate the Swift side installs, so a tab model can stay in sync
// without polling CEF.
class BRWClientHandler : public CefClient,
                         public CefLifeSpanHandler,
                         public CefLoadHandler,
                         public CefDisplayHandler,
                         public CefDownloadHandler {
 public:
  explicit BRWClientHandler(NSView* host_view);

  void SetDelegate(id<BRWBrowserDelegate> delegate) { delegate_ = delegate; }
  id<BRWBrowserDelegate> GetDelegate() { return delegate_; }

  // CefBrowserHost::CreateBrowser is asynchronous -- OnAfterCreated (and thus
  // a non-null GetBrowser()) can lag noticeably behind BRWBrowser's Swift-side
  // construction, especially under CPU contention. A LoadURL request that
  // arrives in that window must not be silently dropped: it's queued here and
  // flushed as soon as OnAfterCreated fires.
  void LoadURLWhenReady(const std::string& url);

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }

  // CefLifeSpanHandler methods:
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;

  // CefLoadHandler methods:
  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                             bool isLoading,
                             bool canGoBack,
                             bool canGoForward) override;
  void OnLoadEnd(CefRefPtr<CefBrowser> browser,
                 CefRefPtr<CefFrame> frame,
                 int httpStatusCode) override;
  void OnLoadError(CefRefPtr<CefBrowser> browser,
                    CefRefPtr<CefFrame> frame,
                    ErrorCode errorCode,
                    const CefString& errorText,
                    const CefString& failedUrl) override;

  // CefDisplayHandler methods:
  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override;
  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        const CefString& url) override;
  void OnFaviconURLChange(CefRefPtr<CefBrowser> browser,
                           const std::vector<CefString>& icon_urls) override;

  // CefDownloadHandler methods:
  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefDownloadItem> download_item,
                         const CefString& suggested_name,
                         CefRefPtr<CefBeforeDownloadCallback> callback) override;
  void OnDownloadUpdated(CefRefPtr<CefBrowser> browser,
                          CefRefPtr<CefDownloadItem> download_item,
                          CefRefPtr<CefDownloadItemCallback> callback) override;

  CefRefPtr<CefBrowser> GetBrowser() { return browser_; }
  bool IsClosed() const { return closed_; }

  // Force-closes every handler with a live browser (i.e. constructed but not
  // yet OnBeforeClose'd). CEF requires every CefBrowser to be closed -- and
  // OnBeforeClose delivered for it -- before CefShutdown runs; this is the
  // "close all browsers" half of that sequence, driven by +[BRWEngine
  // requestShutdownWithCompletion:]. Safe to call with zero live handlers.
  static void CloseAll();

  // Number of handlers still awaiting OnBeforeClose. +[BRWEngine
  // requestShutdownWithCompletion:] polls this down to zero before calling
  // CefShutdown.
  static size_t LiveCount();

 private:
  NSView* host_view_;
  CefRefPtr<CefBrowser> browser_;
  bool closed_ = false;
  // Set by CloseAll() when it runs before OnAfterCreated has fired for this
  // handler (CreateBrowser is asynchronous) -- there's no CefBrowser yet to
  // close, so OnAfterCreated closes it immediately instead of loading.
  bool pending_close_ = false;
  __weak id<BRWBrowserDelegate> delegate_;
  std::string pending_url_;

  IMPLEMENT_REFCOUNTING(BRWClientHandler);
};
