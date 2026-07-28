// Internal C++ interface -- never exposed to Swift.
#pragma once

#import <AppKit/AppKit.h>

#include <set>
#include <string>

#include "include/cef_client.h"
#include "include/cef_display_handler.h"
#include "include/cef_download_handler.h"
#include "include/cef_download_item.h"
#include "include/cef_permission_handler.h"

#import "BRWBrowser.h"  // for the BRWBrowserDelegate protocol only.

// Per-browser callbacks. One instance per BRWBrowser. Owns a reference to the
// NSView the browser is parented into so it can make the CEF-created native
// view track that host view's size via ordinary AppKit autoresizing, instead
// of hand-rolling resize-notification plumbing. Also forwards title/URL/
// favicon/loading-state/navigation-commit/download/permission changes to the
// BRWBrowserDelegate the Swift side installs, so a tab model can stay in sync
// without polling CEF.
class BRWClientHandler : public CefClient,
                         public CefLifeSpanHandler,
                         public CefLoadHandler,
                         public CefDisplayHandler,
                         public CefDownloadHandler,
                         public CefPermissionHandler {
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
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }

  // CefLifeSpanHandler methods:
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;

  // DoClose is deliberately NOT overridden -- CefLifeSpanHandler's default
  // (returning false) is what's required here. Per its own doc comment,
  // returning true means "the application will send a non-standard close
  // notification and complete the browser close itself," and if it then
  // doesn't, "the browser will be left in a partially closed state that
  // interferes with proper functioning." The default instead makes CEF send
  // the standard close notification (-performClose: on macOS, given windowed
  // rendering) to the SetAsChild host view's top-level NSWindow -- our own
  // BrowserWindowController's window -- and it's that window's teardown
  // completing (handled by our own windowWillClose, which closes every
  // tab's BRWBrowser) that actually triggers OnBeforeClose, not
  // CloseBrowser() by itself.
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

  // CefPermissionHandler methods:
  bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser> browser,
                                      CefRefPtr<CefFrame> frame,
                                      const CefString& requesting_origin,
                                      uint32_t requested_permissions,
                                      CefRefPtr<CefMediaAccessCallback> callback) override;
  bool OnShowPermissionPrompt(CefRefPtr<CefBrowser> browser,
                              uint64_t prompt_id,
                              const CefString& requesting_origin,
                              uint32_t requested_permissions,
                              CefRefPtr<CefPermissionPromptCallback> callback) override;
  void OnDismissPermissionPrompt(CefRefPtr<CefBrowser> browser,
                                 uint64_t prompt_id,
                                 cef_permission_request_result_t result) override;

  CefRefPtr<CefBrowser> GetBrowser() { return browser_; }
  bool IsClosed() const { return closed_; }

  // Requests that this handler's browser close -- force-closing (skipping
  // JS beforeunload) -- exactly once no matter how many times this is
  // called, from whichever of -[BRWBrowser close] (a single tab's normal
  // close), CloseAll() (quitting), or OnAfterCreated's pending_close_ flush
  // reaches it first. This dedup is load-bearing, not just tidiness:
  // CefBrowserHost::CloseBrowser() a second time on a browser that's already
  // mid-close never delivers OnBeforeClose at all -- confirmed by hanging
  // shutdown forever (CheckShutdownCompletion ticking correctly, LiveCount()
  // stuck above 0) when a normal per-tab close and CloseAll()'s own pass
  // both requested the same browser's close moments apart. See
  // docs/ai-tasks/quit-crash-notes.md.
  void RequestClose();

  // Force-closes every handler with a live browser (i.e. constructed but not
  // yet OnBeforeClose'd). CEF requires every CefBrowser to be closed -- and
  // OnBeforeClose delivered for it -- before CefShutdown runs; this is the
  // "close all browsers" half of that sequence, driven by +[BRWEngine
  // requestShutdownWithCompletion:]. Safe to call with zero live handlers,
  // and safe to call for a handler whose close was already requested some
  // other way (see RequestClose()).
  static void CloseAll();

  // Number of handlers still awaiting OnBeforeClose. +[BRWEngine
  // requestShutdownWithCompletion:] polls this down to zero before calling
  // CefShutdown.
  static size_t LiveCount();

 private:
  NSView* host_view_;
  CefRefPtr<CefBrowser> browser_;
  bool closed_ = false;
  // Set by RequestClose() when it runs before OnAfterCreated has fired for
  // this handler (CreateBrowser is asynchronous) -- there's no CefBrowser
  // yet to close, so OnAfterCreated closes it immediately instead of loading.
  bool pending_close_ = false;
  // Set the first time RequestClose() actually calls CloseBrowser() --
  // guards against calling it a second time on the same browser (see
  // RequestClose()'s doc comment for why that breaks OnBeforeClose delivery).
  bool close_requested_ = false;
  __weak id<BRWBrowserDelegate> delegate_;
  std::string pending_url_;
  // Synthetic prompt ids for OnRequestMediaAccessPermission, which -- unlike
  // OnShowPermissionPrompt -- gives us no id of its own. Reserves the high
  // bit (see BRWClientHandler.mm's kSyntheticPromptIdBit) so these can never
  // collide with a real CEF-issued prompt_id from the other path; both id
  // spaces flow through the same BRWBrowserDelegate methods on the Swift
  // side.
  uint64_t next_media_prompt_id_ = 1;

  IMPLEMENT_REFCOUNTING(BRWClientHandler);
};
