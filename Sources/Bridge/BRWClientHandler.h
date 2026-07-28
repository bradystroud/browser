// Internal C++ interface -- never exposed to Swift.
#pragma once

#import <AppKit/AppKit.h>

#include <set>
#include <string>

#include "include/cef_client.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_display_handler.h"
#include "include/cef_download_handler.h"
#include "include/cef_download_item.h"
#include "include/cef_find_handler.h"
#include "include/cef_permission_handler.h"
#include "include/cef_request_handler.h"
#include "include/cef_resource_request_handler.h"

#import "BRWBrowser.h"  // for the BRWBrowserDelegate protocol only.

// Per-browser callbacks. One instance per BRWBrowser. Owns a reference to the
// NSView the browser is parented into so it can make the CEF-created native
// view track that host view's size via ordinary AppKit autoresizing, instead
// of hand-rolling resize-notification plumbing. Also forwards title/URL/
// favicon/loading-state/navigation-commit/download/permission/find-result
// changes to the BRWBrowserDelegate the Swift side installs, so a tab model
// can stay in sync without polling CEF.
class BRWClientHandler : public CefClient,
                         public CefLifeSpanHandler,
                         public CefLoadHandler,
                         public CefDisplayHandler,
                         public CefDownloadHandler,
                         public CefPermissionHandler,
                         public CefFindHandler,
                         public CefRequestHandler,
                         public CefResourceRequestHandler,
                         public CefContextMenuHandler {
 public:
  // `profile_name` identifies which profile's BlockingSettings apply to
  // this browser's requests -- see OnBeforeResourceLoad below
  // (browser-12m.5.1). Matches the same profile name BRWBrowser passes to
  // BRWGetOrCreateProfileContext for its CefRequestContext.
  BRWClientHandler(NSView* host_view, const std::string& profile_name);

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
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  // Unlike CefCommandHandler (browser-5kq.1/browser-6hi.1's own investigations
  // both found that interface "Only used with Chrome style") --
  // CefContextMenuHandler is a plain CefClient handler with no such
  // restriction, and does fire for Alloy-style browsers: this app's existing
  // native right-click menu (copy/paste, etc.) already comes from CEF's own
  // default context-menu implementation, which this handler customizes
  // rather than replaces (browser-5kq.2).
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }

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
  // Fires "after a navigation has been committed and before the browser
  // begins loading contents in the frame" (CEF's own doc comment) -- i.e.
  // before the new document's own scripts run. This is the "document-start"
  // hook browser-ojh.1's password-form-detection script needs (via
  // -browserDidStartMainFrameLoad on the delegate), not OnLoadingStateChange
  // above, which fires browser-wide rather than per-frame and doesn't
  // guarantee the new frame/document already exists.
  void OnLoadStart(CefRefPtr<CefBrowser> browser,
                    CefRefPtr<CefFrame> frame,
                    TransitionType transition_type) override;
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

  // CefFindHandler methods:
  void OnFindResult(CefRefPtr<CefBrowser> browser,
                     int identifier,
                     int count,
                     const CefRect& selectionRect,
                     int activeMatchOrdinal,
                     bool finalUpdate) override;

  // CefContextMenuHandler methods:
  // Adds a "Look Up Image" entry to CEF's own default context menu when
  // right-clicking an image (browser-5kq.2) -- only when Visual Look Up is
  // actually supported on this Mac (checked Swift-side via
  // ImageAnalyzer.isSupported before this handler is even installed; see
  // BRWBrowser.mm's -setVisualLookUpAvailable:).
  void OnBeforeContextMenu(CefRefPtr<CefBrowser> browser,
                            CefRefPtr<CefFrame> frame,
                            CefRefPtr<CefContextMenuParams> params,
                            CefRefPtr<CefMenuModel> model) override;
  // Handles the "Look Up Image" command by forwarding the image's source URL
  // (and the page URL, for a Referer header on the follow-up fetch) to the
  // delegate -- returns true (handled) only for that one command id; every
  // other command id returns false so CEF's own default handling (copy,
  // paste, spelling suggestions, etc.) still works exactly as before this
  // handler was added.
  bool OnContextMenuCommand(CefRefPtr<CefBrowser> browser,
                             CefRefPtr<CefFrame> frame,
                             CefRefPtr<CefContextMenuParams> params,
                             int command_id,
                             EventFlags event_flags) override;

  // CefClient methods:
  // Forwards to BRWPageMessageRouter -- see that class's own doc comment
  // for what this generic JS<->native channel is for (browser-ojh.1).
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                 CefRefPtr<CefFrame> frame,
                                 CefProcessId source_process,
                                 CefRefPtr<CefProcessMessage> message) override;

  // CefRequestHandler methods:
  // Both forward to BRWPageMessageRouter, exactly as its own doc comments
  // require -- unrelated to the content-blocker methods below despite
  // living on the same CefRequestHandler interface.
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       CefRefPtr<CefRequest> request,
                       bool user_gesture,
                       bool is_redirect) override;
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                  TerminationStatus status,
                                  int error_code,
                                  const CefString& error_string) override;

  // CefRequestHandler methods:
  // Returning `this` means OnBeforeResourceLoad below (this same object,
  // via CefResourceRequestHandler) is called for every resource this
  // browser loads -- content-blocker enforcement (browser-12m.5.1). Called
  // on the IO thread.
  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request,
      bool is_navigation,
      bool is_download,
      const CefString& request_initiator,
      bool& disable_default_handling) override {
    return this;
  }

  // CefResourceRequestHandler methods:
  // Called on the IO thread, once per resource request this browser makes.
  // Cancels (RV_CANCEL) any request whose host the content blocker says to
  // block for this browser's profile -- see BRWContentBlockerShouldBlock
  // (BRWContentBlockerInternal.h) for the actual (lock-free) lookup this
  // defers to. Also handles the threat-list check (browser-12m.6, see
  // BRWThreatListInternal.h) -- a subresource hit is cancelled the same
  // silent way as an ad, but a main-frame hit instead hops to the UI thread
  // to load a warning interstitial in place of the cancelled navigation;
  // this method itself never touches Swift or AppKit directly, and must
  // stay safe to call from the IO thread.
  ReturnValue OnBeforeResourceLoad(CefRefPtr<CefBrowser> browser,
                                    CefRefPtr<CefFrame> frame,
                                    CefRefPtr<CefRequest> request,
                                    CefRefPtr<CefCallback> callback) override;

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

  // Finds the handler owning `browser`, if any -- used by
  // BRWPageMessageRouter to route an incoming page message to the right
  // tab's delegate. nullptr if `browser` doesn't match any live handler
  // (e.g. it's already been closed).
  static BRWClientHandler* ForBrowser(CefRefPtr<CefBrowser> browser);

  // Whether to offer "Look Up Image" in the context menu at all
  // (browser-5kq.2) -- a Mac-wide hardware/OS capability
  // (ImageAnalyzer.isSupported), not something that varies per browser/tab,
  // so this is process-wide rather than a per-instance member. Set once at
  // launch by -[BRWBrowser setVisualLookUpAvailable:]; defaults to false
  // (no menu item) until Swift confirms support, rather than risking
  // offering a menu item that would do nothing on an unsupported Mac.
  static void SetVisualLookUpAvailable(bool available) { visual_look_up_available_ = available; }

 private:
  NSView* host_view_;
  // Which profile's BlockingSettings apply to this browser's requests --
  // see OnBeforeResourceLoad. Set once at construction, never changes for
  // this handler's lifetime (matches BRWBrowser: a tab's profile is fixed
  // at creation, see docs/plans's per-window/per-tab profile identity).
  std::string profile_name_;
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

  // See SetVisualLookUpAvailable's own doc comment for why this is static.
  static bool visual_look_up_available_;

  IMPLEMENT_REFCOUNTING(BRWClientHandler);
};
