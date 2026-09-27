#import "BRWClientHandler.h"
#import "BRWContentBlockerInternal.h"
#import "BRWPageMessageRouter.h"
#import "BRWStringUtil.h"
#import "BRWThreatListInternal.h"

#include <cstdlib>
#include <vector>

#include "include/cef_parser.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_helpers.h"

namespace {
// Wraps an Obj-C block as a CefTask -- CefPostTask needs a CefRefPtr<CefTask>,
// not a lambda/block directly. Same wrap-a-block pattern as BRWBrowser.mm's
// StringVisitorBlock/PdfPrintCallback, just for CefTask instead of those
// classes' own CEF interfaces.
class BRWBlockTask : public CefTask {
 public:
  explicit BRWBlockTask(void (^block)(void)) : block_([block copy]) {}

  void Execute() override {
    if (block_) {
      block_();
    }
  }

 private:
  void (^block_)(void);
  IMPLEMENT_REFCOUNTING(BRWBlockTask);
};

// CEF's rich cef_window_open_disposition_t collapsed onto the four cases this
// app's UI actually distinguishes. Shared by OnBeforePopup (target="_blank" /
// window.open()) and OnOpenURLFromTab (Cmd/Shift/middle-click on a plain
// link) so both routes agree on what a disposition means.
BRWWindowOpenDisposition TranslateDisposition(cef_window_open_disposition_t d) {
  switch (d) {
    case CEF_WOD_NEW_BACKGROUND_TAB:
      return BRWWindowOpenDispositionBackgroundTab;
    case CEF_WOD_NEW_POPUP:
      return BRWWindowOpenDispositionNewPopup;
    case CEF_WOD_NEW_WINDOW:
      return BRWWindowOpenDispositionNewWindow;
    default:
      // Includes NEW_FOREGROUND_TAB (the common target="_blank" case) and
      // every other value CEF's own richer enum has (singleton tab, save-to-
      // disk, switch-to-tab, etc.) -- none of which this app distinguishes;
      // a new foreground tab is the closest standard-browser match for all
      // of them.
      return BRWWindowOpenDispositionForegroundTab;
  }
}

// An http(s) origin as (scheme, lowercased host, effective port), or false
// when `url` has none. A blob: URL yields the origin embedded in it.
bool HTTPOriginOf(const std::string& url, std::string* scheme, std::string* host, int* port) {
  std::string target = url;
  if (ToLowerASCII(target.substr(0, 5)) == "blob:") {
    target = target.substr(5);
  }
  CefURLParts parts;
  if (!CefParseURL(target, parts)) {
    return false;
  }
  *scheme = ToLowerASCII(CefString(&parts.scheme).ToString());
  if (*scheme != "http" && *scheme != "https") {
    return false;
  }
  *host = ToLowerASCII(CefString(&parts.host).ToString());
  if (host->empty()) {
    return false;
  }
  const std::string port_string = CefString(&parts.port).ToString();
  *port = port_string.empty() ? (*scheme == "https" ? 443 : 80) : atoi(port_string.c_str());
  return true;
}

// The C++ copy of PopupTargetPolicy (Packages/WebEngineCore), which carries
// the full rationale: a page may only put http(s), about:blank, or a blob it
// created itself into a new top-level tab. Kept in step with it by hand --
// this runs on CEF's UI thread and cannot call into Swift.
bool BRWPopupTargetAllowed(const std::string& target_url, const std::string& opener_frame_url) {
  if (target_url.empty()) {
    return true;  // window.open() with no URL: a blank page.
  }
  const std::string lower = ToLowerASCII(target_url);
  if (lower == "about:blank") {
    return true;
  }
  std::string scheme, host;
  int port = 0;
  if (lower.rfind("http:", 0) == 0 || lower.rfind("https:", 0) == 0) {
    return HTTPOriginOf(target_url, &scheme, &host, &port);
  }
  if (lower.rfind("blob:", 0) == 0) {
    std::string opener_scheme, opener_host;
    int opener_port = 0;
    return HTTPOriginOf(target_url, &scheme, &host, &port) &&
           HTTPOriginOf(opener_frame_url, &opener_scheme, &opener_host, &opener_port) &&
           scheme == opener_scheme && host == opener_host && port == opener_port;
  }
  return false;
}

// Every handler constructed but not yet OnBeforeClose'd. Only ever touched on
// the CEF UI thread (== main thread, given this app's single-threaded,
// external-message-pump CefSettings), so no locking is needed.
std::set<BRWClientHandler*>& Registry() {
  static std::set<BRWClientHandler*> registry;
  return registry;
}
}  // namespace

BRWClientHandler::BRWClientHandler(NSView* host_view, const std::string& profile_name)
    : host_view_(host_view), profile_name_(profile_name) {
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
  BRWPageMessageRouter::Get().OnBeforeClose(browser);
  BRWDevToolsHandler::Close(this);
  closed_ = true;
  browser_ = nullptr;
  Registry().erase(this);
}

bool BRWClientHandler::OnBeforePopup(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    int popup_id,
    const CefString& target_url,
    const CefString& target_frame_name,
    WindowOpenDisposition target_disposition,
    bool user_gesture,
    const CefPopupFeatures& popupFeatures,
    CefWindowInfo& windowInfo,
    CefRefPtr<CefClient>& client,
    CefBrowserSettings& settings,
    CefRefPtr<CefDictionaryValue>& extra_info,
    bool* no_javascript_access) {
  CEF_REQUIRE_UI_THREAD();

  if (target_disposition == CEF_WOD_NEW_PICTURE_IN_PICTURE) {
    // Document Picture-in-Picture (documentPictureInPicture.requestWindow())
    // needs CEF's own default handling to produce the special floating
    // window Chromium manages internally -- turning this into a regular tab
    // would break the feature. This app's own <video>.requestPictureInPicture()
    // (browser-7jz.1) is a different, unrelated code path that never reaches
    // OnBeforePopup at all -- see cefclient's own reference OnBeforePopup
    // (tests/cefclient/browser/client_handler.cc) for the same special case.
    return false;
  }

  // Alloy has no popup blocker of its own: without this, any page could
  // open tabs at will from a timer or on load. A real click on a
  // target="_blank" link carries a gesture and still gets through.
  if (!user_gesture) {
    NSLog(@"Browser: refused a page-opened window with no user gesture");
    return true;
  }
  // The delegate loads the target as a fresh, browser-initiated navigation,
  // which Chromium's own block on page-initiated top-level data: loads
  // doesn't cover -- so the scheme is checked here.
  const std::string opener_url = frame ? frame->GetURL().ToString() : std::string();
  if (!BRWPopupTargetAllowed(target_url.ToString(), opener_url)) {
    NSLog(@"Browser: refused a page-opened window for a disallowed URL scheme");
    return true;
  }

  if (delegate_ && [delegate_ respondsToSelector:@selector(browserDidRequestNewTabForURL:disposition:)]) {
    [delegate_ browserDidRequestNewTabForURL:ToNSString(target_url)
                                 disposition:TranslateDisposition(target_disposition)];
  }

  // Always cancel CEF's own popup/window creation -- the delegate above is
  // responsible for every disposition itself (a new tab in this window, or
  // a genuine Swift-owned BrowserWindow for *NewWindow/*NewPopup), never a
  // raw CEF-created window with no toolbar/tab strip/session-restore/quit-
  // sequencing integration.
  return true;
}

bool BRWClientHandler::OnOpenURLFromTab(CefRefPtr<CefBrowser> browser,
                                        CefRefPtr<CefFrame> frame,
                                        const CefString& target_url,
                                        WindowOpenDisposition target_disposition,
                                        bool user_gesture) {
  CEF_REQUIRE_UI_THREAD();

  // A plain <a href> with no target is an ordinary same-frame navigation:
  // Blink never asks for a new browsing context, so OnBeforePopup is never
  // consulted for it. Cmd-click / Cmd+Shift-click / Shift-click / middle-
  // click on such a link is resolved by Blink itself into a non-current-tab
  // NavigationPolicy, which reaches the browser process as an OpenURLFromTab
  // with the corresponding disposition -- here. That means Chromium's own
  // modifier interpretation (which already matches macOS conventions, and
  // already respects a page's own preventDefault(), since a cancelled click
  // never starts a navigation at all) is the authority; nothing here reads
  // the live keyboard state.
  switch (target_disposition) {
    case CEF_WOD_NEW_BACKGROUND_TAB:  // Cmd-click, middle-click
    case CEF_WOD_NEW_FOREGROUND_TAB:
    case CEF_WOD_NEW_WINDOW:          // Shift-click
    case CEF_WOD_NEW_POPUP:
      break;
    default:
      // Notably CEF_WOD_CURRENT_TAB: this callback also fires for certain
      // renderer-initiated cross-origin navigations (e.g. to/from a file
      // URL) that must simply proceed in the source browser, not spawn a
      // tab. Same shape as cefclient's own reference OnOpenURLFromTab
      // (tests/cefclient/browser/client_handler.cc).
      return false;
  }

  // Same rules as OnBeforePopup: a new tab needs a real click, and only
  // for a URL a page may open. Either failing cancels the navigation
  // outright rather than letting it proceed in the current tab.
  const std::string opener_url = frame ? frame->GetURL().ToString() : std::string();
  if (!user_gesture || !BRWPopupTargetAllowed(target_url.ToString(), opener_url)) {
    NSLog(@"Browser: refused a new tab (gesture=%d)", user_gesture ? 1 : 0);
    return true;
  }

  if (delegate_ && [delegate_ respondsToSelector:@selector(browserDidRequestNewTabForURL:disposition:)]) {
    [delegate_ browserDidRequestNewTabForURL:ToNSString(target_url)
                                 disposition:TranslateDisposition(target_disposition)];
    // Cancel the source browser's own navigation -- the delegate is opening
    // this URL somewhere else.
    return true;
  }
  return false;
}

bool BRWClientHandler::DoClose(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  if (close_requested_ || closed_ || !browser_ || !browser_->IsSame(browser)) {
    return false;
  }
  __weak id<BRWBrowserDelegate> delegate = delegate_;
  if (![delegate respondsToSelector:@selector(browserDidRequestClose)]) {
    return false;
  }
  // Deferred: the delegate's answer is RequestClose(), which must not
  // re-enter CloseBrowser() from inside CEF's own close callback.
  dispatch_async(dispatch_get_main_queue(), ^{
    [delegate browserDidRequestClose];
  });
  return true;
}

void BRWClientHandler::RequestClose() {
  CEF_REQUIRE_UI_THREAD();
  if (closed_ || close_requested_) {
    return;
  }
  // DevTools first, while this browser can still close it through CEF's own
  // DevTools manager (see BRWDevToolsHandler::RequestClose).
  BRWDevToolsHandler::Close(this);
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
  // DevTools browsers whose inspected page has already gone.
  BRWDevToolsHandler::CloseAll();
}

// static
size_t BRWClientHandler::LiveCount() {
  return Registry().size() + BRWDevToolsHandler::LiveCount();
}

// static
BRWClientHandler* BRWClientHandler::ForBrowser(CefRefPtr<CefBrowser> browser) {
  if (!browser) {
    return nullptr;
  }
  int identifier = browser->GetIdentifier();
  for (BRWClientHandler* handler : Registry()) {
    if (handler->browser_ && handler->browser_->GetIdentifier() == identifier) {
      return handler;
    }
  }
  return nullptr;
}

void BRWClientHandler::OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                                              bool isLoading,
                                              bool canGoBack,
                                              bool canGoForward) {
  if (delegate_ && [delegate_ respondsToSelector:@selector(browserDidChangeLoadingState:canGoBack:canGoForward:)]) {
    [delegate_ browserDidChangeLoadingState:isLoading canGoBack:canGoBack canGoForward:canGoForward];
  }
}

void BRWClientHandler::OnLoadStart(CefRefPtr<CefBrowser> browser,
                                     CefRefPtr<CefFrame> frame,
                                     TransitionType transition_type) {
  // Only the main frame's document-start matters for page-level feature
  // scripts (password-form detection today) -- an iframe's own scripts
  // aren't where a site's login form normally lives, and injecting there
  // too would just multiply cefQuery traffic for no benefit in v1.
  if (!frame->IsMain()) {
    return;
  }
  if (delegate_ && [delegate_ respondsToSelector:@selector(browserDidStartMainFrameLoadWithURL:)]) {
    [delegate_ browserDidStartMainFrameLoadWithURL:ToNSString(frame->GetURL())];
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

void BRWClientHandler::OnLoadingProgressChange(CefRefPtr<CefBrowser> browser, double progress) {
  if (delegate_ && [delegate_ respondsToSelector:@selector(browserDidUpdateLoadingProgress:)]) {
    [delegate_ browserDidUpdateLoadingProgress:progress];
  }
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
  // Reached by page-initiated downloads *and* by -[BRWBrowser
  // startDownloadForURL:] (browser-5kq.14) -- CefBrowserHost::StartDownload
  // is documented as downloading "using CefDownloadHandler", i.e. through
  // this very callback, so "Download Image" gets the app's whole existing
  // download pipeline (unique-filename resolution below, DownloadStore, the
  // Downloads window) with no second code path.
  NSString* downloads_dir =
      download_directory_.empty()
          ? [NSHomeDirectory() stringByAppendingPathComponent:@"Downloads"]
          : [NSString stringWithUTF8String:download_directory_.c_str()];
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

namespace {
BRWPermissionKind ToBRWPermissionKindFromMedia(uint32_t cef_media_permissions) {
  BRWPermissionKind kinds = 0;
  if (cef_media_permissions & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) {
    kinds |= BRWPermissionKindCamera;
  }
  if (cef_media_permissions & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) {
    kinds |= BRWPermissionKindMicrophone;
  }
  // Desktop capture (screen/window sharing) isn't one of the four kinds
  // this app's UI supports yet (see BRWBrowser.h) -- intentionally not
  // translated, so a desktop-capture-only request falls through to CEF's
  // own default handling (deny, in Alloy style) rather than silently
  // mis-mapping it onto camera/microphone.
  return kinds;
}

BRWPermissionKind ToBRWPermissionKindFromPrompt(uint32_t cef_permission_types) {
  BRWPermissionKind kinds = 0;
  if (cef_permission_types & CEF_PERMISSION_TYPE_GEOLOCATION) {
    kinds |= BRWPermissionKindGeolocation;
  }
  if (cef_permission_types & CEF_PERMISSION_TYPE_NOTIFICATIONS) {
    kinds |= BRWPermissionKindNotifications;
  }
  // Every other CEF_PERMISSION_TYPE_* (clipboard, MIDI sysex, local fonts,
  // storage access, etc.) isn't in this app's supported set yet -- falls
  // through to CEF's own default (Alloy style: CEF_PERMISSION_RESULT_IGNORE)
  // the same way an unsupported media type does above.
  return kinds;
}

// Reserved so synthetic ids minted for the media-access path (which CEF
// gives no id of its own) can never collide with a real CEF-issued
// prompt_id from the permission-prompt path (OnShowPermissionPrompt /
// OnDismissPermissionPrompt) -- both id spaces flow through the same
// BRWBrowserDelegate methods on the Swift side.
constexpr uint64_t kSyntheticPromptIdBit = 1ULL << 63;
}  // namespace

bool BRWClientHandler::OnRequestMediaAccessPermission(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    const CefString& requesting_origin,
    uint32_t requested_permissions,
    CefRefPtr<CefMediaAccessCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  BRWPermissionKind kinds = ToBRWPermissionKindFromMedia(requested_permissions);
  if (kinds == 0 || !delegate_ ||
      ![delegate_ respondsToSelector:@selector(browserDidRequestPermission:promptId:requestingOrigin:decision:)]) {
    return false;  // Proceed with CEF's own default handling (deny, in Alloy style).
  }

  uint64_t prompt_id = kSyntheticPromptIdBit | next_media_prompt_id_++;
  [delegate_ browserDidRequestPermission:kinds
                                 promptId:prompt_id
                         requestingOrigin:ToNSString(requesting_origin)
                                 decision:^(BOOL allow) {
    // getUserMedia requires allowed_permissions to exactly match
    // required_permissions when granting -- partial grants aren't valid
    // for a bundled request, see CefMediaAccessCallback::Continue's own
    // doc comment.
    callback->Continue(allow ? requested_permissions : 0);
  }];
  return true;
}

bool BRWClientHandler::OnShowPermissionPrompt(
    CefRefPtr<CefBrowser> browser,
    uint64_t prompt_id,
    const CefString& requesting_origin,
    uint32_t requested_permissions,
    CefRefPtr<CefPermissionPromptCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  BRWPermissionKind kinds = ToBRWPermissionKindFromPrompt(requested_permissions);
  if (kinds == 0 || !delegate_ ||
      ![delegate_ respondsToSelector:@selector(browserDidRequestPermission:promptId:requestingOrigin:decision:)]) {
    return false;  // Proceed with CEF's own default handling (Alloy style: CEF_PERMISSION_RESULT_IGNORE).
  }

  [delegate_ browserDidRequestPermission:kinds
                                 promptId:prompt_id
                         requestingOrigin:ToNSString(requesting_origin)
                                 decision:^(BOOL allow) {
    callback->Continue(allow ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY);
  }];
  return true;
}

void BRWClientHandler::OnDismissPermissionPrompt(CefRefPtr<CefBrowser> browser,
                                                  uint64_t prompt_id,
                                                  cef_permission_request_result_t result) {
  if (delegate_ && [delegate_ respondsToSelector:@selector(browserDidDismissPermissionRequest:)]) {
    [delegate_ browserDidDismissPermissionRequest:prompt_id];
  }
}

void BRWClientHandler::OnFindResult(CefRefPtr<CefBrowser> browser,
                                     int identifier,
                                     int count,
                                     const CefRect& selectionRect,
                                     int activeMatchOrdinal,
                                     bool finalUpdate) {
  // |identifier| (a per-search-session id) and |selectionRect| (the
  // matched text's on-screen location) aren't surfaced -- CEF/Chromium
  // already highlights matches on the page itself, so this bridge only
  // needs the count/position for the find bar's "N of M" label, not to draw
  // anything itself.
  if (delegate_ && [delegate_ respondsToSelector:@selector(browserDidUpdateFindResultWithMatchCount:activeMatchOrdinal:finalUpdate:)]) {
    [delegate_ browserDidUpdateFindResultWithMatchCount:count
                                     activeMatchOrdinal:activeMatchOrdinal
                                            finalUpdate:finalUpdate];
  }
}

namespace {
// User-defined menu ids must fall between MENU_ID_USER_FIRST and
// MENU_ID_USER_LAST (see cef_types.h).
const int kVisualLookUpCommandId = MENU_ID_USER_FIRST;
const int kCopyImageCommandId = MENU_ID_USER_FIRST + 1;
const int kCopyImageLinkCommandId = MENU_ID_USER_FIRST + 2;
const int kDownloadImageCommandId = MENU_ID_USER_FIRST + 3;
const int kViewSourceCommandId = MENU_ID_USER_FIRST + 4;
const int kInspectElementCommandId = MENU_ID_USER_FIRST + 5;
}  // namespace

// static
bool BRWClientHandler::visual_look_up_available_ = false;

// static
std::string BRWClientHandler::download_directory_;

void BRWClientHandler::OnBeforeContextMenu(CefRefPtr<CefBrowser> browser,
                                             CefRefPtr<CefFrame> frame,
                                             CefRefPtr<CefContextMenuParams> params,
                                             CefRefPtr<CefMenuModel> model) {
  // The image items fetch, copy or save the image's address from the
  // browser process, where the page's own limits don't apply -- so only an
  // address a page could itself load qualifies, never another app's scheme
  // a page merely names, and file: only on a page that is itself a local
  // file the user opened.
  const std::string image_url = params->GetSourceUrl().ToString();
  const bool page_is_file = params->GetPageUrl().ToString().rfind("file:", 0) == 0;
  const bool image_url_allowed = image_url.rfind("http:", 0) == 0 || image_url.rfind("https:", 0) == 0 ||
                                 image_url.rfind("data:", 0) == 0 || image_url.rfind("blob:", 0) == 0 ||
                                 (page_is_file && image_url.rfind("file:", 0) == 0);
  if (params->HasImageContents() && image_url_allowed) {
    if (model->GetCount() > 0) {
      model->AddSeparator();
    }
    // Copy Image / Copy Image Link (browser-5kq.13) and Download Image
    // (browser-5kq.14) are unconditional; "Look Up Image" additionally needs
    // the Mac to support VisionKit analysis at all (browser-5kq.2), so it can
    // be absent while the other three are there.
    model->AddItem(kCopyImageCommandId, "Copy Image");
    model->AddItem(kCopyImageLinkCommandId, "Copy Image Link");
    model->AddItem(kDownloadImageCommandId, "Download Image");
    if (visual_look_up_available_) {
      model->AddItem(kVisualLookUpCommandId, "Look Up Image");
    }
  }

  // View Page Source / Inspect Element go on *every* right-click, image or
  // not, which is where both Safari and Chrome put them.
  //
  // CEF's own MENU_ID_VIEW_SOURCE is removed rather than left alongside ours.
  // It is not a broken item so much as a differently-scoped one: it routes to
  // CefFrame::ViewSource(), documented as saving the frame's HTML to a
  // temporary file and handing that to "the default text viewing
  // application" -- so it leaves the browser entirely, which is why it reads
  // as doing nothing. Ours navigates a new tab to `view-source:<url>` and
  // gets Chromium's real source viewer, syntax highlighting and all
  // (confirmed working in this Alloy app before this item was written).
  model->Remove(MENU_ID_VIEW_SOURCE);
  if (model->GetCount() > 0) {
    model->AddSeparator();
  }
  model->AddItem(kViewSourceCommandId, "View Page Source");
  model->AddItem(kInspectElementCommandId, "Inspect Element");
}

bool BRWClientHandler::OnContextMenuCommand(CefRefPtr<CefBrowser> browser,
                                              CefRefPtr<CefFrame> frame,
                                              CefRefPtr<CefContextMenuParams> params,
                                              int command_id,
                                              EventFlags event_flags) {
  switch (command_id) {
    case kVisualLookUpCommandId:
      if (delegate_ &&
          [delegate_ respondsToSelector:@selector(browserDidRequestVisualLookUpForImageURL:pageURL:)]) {
        [delegate_ browserDidRequestVisualLookUpForImageURL:ToNSString(params->GetSourceUrl())
                                                     pageURL:ToNSString(params->GetPageUrl())];
      }
      return true;
    case kCopyImageCommandId:
      if (delegate_ &&
          [delegate_ respondsToSelector:@selector(browserDidRequestCopyImageForImageURL:pageURL:)]) {
        [delegate_ browserDidRequestCopyImageForImageURL:ToNSString(params->GetSourceUrl())
                                                   pageURL:ToNSString(params->GetPageUrl())];
      }
      return true;
    case kCopyImageLinkCommandId:
      if (delegate_ &&
          [delegate_ respondsToSelector:@selector(browserDidRequestCopyImageLinkForImageURL:)]) {
        [delegate_ browserDidRequestCopyImageLinkForImageURL:ToNSString(params->GetSourceUrl())];
      }
      return true;
    case kDownloadImageCommandId:
      if (delegate_ &&
          [delegate_ respondsToSelector:@selector(browserDidRequestDownloadImageForImageURL:)]) {
        [delegate_ browserDidRequestDownloadImageForImageURL:ToNSString(params->GetSourceUrl())];
      }
      return true;
    case kViewSourceCommandId:
      if (delegate_ &&
          [delegate_ respondsToSelector:@selector(browserDidRequestViewSourceForPageURL:)]) {
        [delegate_ browserDidRequestViewSourceForPageURL:ToNSString(params->GetPageUrl())];
      }
      return true;
    case kInspectElementCommandId: {
      // The point the user right-clicked, so DevTools opens with that element
      // already selected. The delegate decides where DevTools goes (it owns
      // the dock container) and answers with -inspectElementAtPoint:inView:;
      // without one, DevTools reuses its last container, or CEF's own window.
      const int x = params->GetXCoord();
      const int y = params->GetYCoord();
      if (delegate_ && [delegate_ respondsToSelector:@selector(browserDidRequestInspectElementAtPoint:)]) {
        const CGFloat height = host_view_ ? host_view_.bounds.size.height : 0;
        const CGFloat view_y = (host_view_ && !host_view_.isFlipped) ? height - y : y;
        [delegate_ browserDidRequestInspectElementAtPoint:NSMakePoint(x, view_y)];
        return true;
      }
      BRWDevToolsHandler::Request request;
      request.container = last_devtools_container_;
      request.has_point = true;
      request.x = x;
      request.y = y;
      BRWDevToolsHandler::Show(this, request);
      return true;
    }
    default:
      // Not ours -- let CEF's default handling take it (copy/paste, spelling
      // suggestions, etc.), exactly as if this handler didn't exist.
      return false;
  }
}

BRWClientHandler::ReturnValue BRWClientHandler::OnBeforeResourceLoad(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    CefRefPtr<CefRequest> request,
    CefRefPtr<CefCallback> callback) {
  // Runs on the IO thread, once per resource request -- deliberately no
  // CEF_REQUIRE_UI_THREAD() here, unlike most of this file's other
  // overrides. profile_name_ is set once at construction and never
  // mutated, so reading it from any thread is safe without synchronization;
  // BRWContentBlockerShouldBlock/BRWThreatListShouldWarn are themselves
  // documented lock-free/lock-only-when-necessary on this hot path (see
  // BRWContentBlockerInternal.h / BRWThreatListInternal.h).
  const std::string raw_url = request->GetURL().ToString();

  // The "Continue anyway (unsafe)" link on our own warning interstitial
  // (browser-12m.6) -- recognized before any real URL parsing, since it's
  // never a real destination: intercepting it, recording the bypass, and
  // re-issuing the original navigation (which will now pass
  // BRWThreatListShouldWarn) all happen right here, reusing this same
  // interception point rather than needing any new JS/message-channel
  // plumbing to get "the user clicked continue" back to native code.
  std::string original_url;
  if (BRWThreatListParseContinueMarker(raw_url, &original_url)) {
    // Honoured only as a top-level navigation away from the exact warning
    // page this browser was shown -- anything else (a subresource, an
    // iframe, a marker link on some other page) could otherwise grant
    // itself a bypass. A refused marker is still cancelled: its host is
    // reserved and never resolves anyway.
    const bool is_genuine_continue =
        browser && frame && frame->IsMain() &&
        request->GetResourceType() == RT_MAIN_FRAME &&
        BRWThreatListConsumeContinue(browser->GetIdentifier(), frame->GetURL().ToString(), original_url);
    if (!is_genuine_continue) {
      return RV_CANCEL;
    }
    CefURLParts original_parts;
    std::string original_host;
    if (CefParseURL(original_url, original_parts)) {
      original_host = CefString(&original_parts.host).ToString();
    }
    BRWThreatListAddSessionBypass(profile_name_, original_host);
    // LoadURL is documented callable from any thread in the browser process
    // (see CefFrame's class comment), but this still hops to the UI thread
    // rather than calling it inline here -- consistency with the
    // interstitial-loading path just below, which *does* need the UI
    // thread (it calls into Swift), and this codebase's established
    // caution around calling back into CEF's own navigation machinery from
    // inside a resource-load callback (see BRWMessagePump.mm's
    // OnScheduleMessagePumpWork notes).
    CefRefPtr<CefFrame> target_frame = frame;
    const std::string url_to_load = original_url;
    CefPostTask(TID_UI, new BRWBlockTask(^{
      if (target_frame && target_frame->IsValid()) {
        target_frame->LoadURL(url_to_load);
      }
    }));
    return RV_CANCEL;
  }

  CefURLParts parts;
  if (!CefParseURL(request->GetURL(), parts)) {
    return RV_CONTINUE;  // Unparseable URL -- fail open, don't block.
  }
  std::string host = CefString(&parts.host).ToString();
  std::string matched_domain;
  if (BRWContentBlockerShouldBlock(profile_name_, host, &matched_domain)) {
    // Report the block back to the delegate so the toolbar badge
    // (Tab.blockedRequestCount) actually reflects it -- delegate_ is only
    // safe to message on the UI thread, but reading a __weak reference
    // itself is thread-safe (internally synchronized), so promote to a
    // strong local here on the IO thread and hop to UI to deliver it, same
    // pattern as the continue-marker/threat-list branches above.
    id<BRWBrowserDelegate> strong_delegate = delegate_;
    if (strong_delegate &&
        [strong_delegate respondsToSelector:@selector(browserDidBlockRequestToTracker:onPageHost:)]) {
      // Read the main frame's host HERE, on the IO thread, rather than in
      // the block below: the hop to the UI thread means a block from the
      // outgoing page can be delivered after the next navigation has
      // started, and asking then would attribute this tracker to whatever
      // page happens to be current by the time it lands. See
      // -browserDidBlockRequestToTracker:onPageHost: for the thread-safety
      // this relies on.
      std::string page_host;
      CefRefPtr<CefFrame> main_frame = browser ? browser->GetMainFrame() : nullptr;
      if (main_frame) {
        CefURLParts main_parts;
        if (CefParseURL(main_frame->GetURL(), main_parts)) {
          page_host = CefString(&main_parts.host).ToString();
        }
      }
      NSString *tracker_domain = ToNSString(CefString(matched_domain));
      NSString *page_host_string = ToNSString(CefString(page_host));
      CefPostTask(TID_UI, new BRWBlockTask(^{
        [strong_delegate browserDidBlockRequestToTracker:tracker_domain onPageHost:page_host_string];
      }));
    }
    return RV_CANCEL;
  }

  // Threat-list check (browser-12m.6) -- deliberately separate from the
  // ad/tracker check above: a top-level (main-frame) hit gets a warning
  // interstitial the user can click through, matching real browsers'
  // Safe-Browsing-style warnings; a subresource hit (an <img>/<script>/etc.
  // pulled in from a flagged host) is silently cancelled instead, exactly
  // like an ad -- there's no page to interrupt the user with a warning
  // about (see browser-12m.3's finding for why this app isn't wired to
  // Google's own Safe Browsing and builds this local list instead).
  if (BRWThreatListShouldWarn(profile_name_, host)) {
    if (request->GetResourceType() == RT_MAIN_FRAME) {
      CefRefPtr<CefFrame> target_frame = frame;
      const std::string target_host = host;
      const std::string blocked_url = raw_url;
      const int browser_id = browser ? browser->GetIdentifier() : 0;
      CefPostTask(TID_UI, new BRWBlockTask(^{
        if (!target_frame || !target_frame->IsValid()) {
          return;
        }
        const std::string interstitial_url = BRWThreatListBuildInterstitialURL(target_host, blocked_url);
        if (!interstitial_url.empty()) {
          // Recorded on the IO thread, where the continue marker is checked,
          // and queued ahead of the load so it is always in place first.
          CefPostTask(TID_IO, new BRWBlockTask(^{
            BRWThreatListNoteInterstitial(browser_id, interstitial_url, blocked_url);
          }));
          target_frame->LoadURL(interstitial_url);
        }
      }));
    }
    return RV_CANCEL;
  }

  return RV_CONTINUE;
}

bool BRWClientHandler::OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                                 CefRefPtr<CefFrame> frame,
                                                 CefProcessId source_process,
                                                 CefRefPtr<CefProcessMessage> message) {
  return BRWPageMessageRouter::Get().OnProcessMessageReceived(browser, frame, source_process, message);
}

bool BRWClientHandler::OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                                       CefRefPtr<CefFrame> frame,
                                       CefRefPtr<CefRequest> request,
                                       bool user_gesture,
                                       bool is_redirect) {
  // The DevTools front-end only ever runs in a browser BRWDevToolsHandler
  // created for it. Chromium already keeps web content from navigating to
  // devtools://; this also refuses it when typed or loaded directly, so an
  // ordinary tab never hosts a front-end at all.
  if (request->GetURL().ToString().rfind("devtools:", 0) == 0) {
    return true;
  }
  // Must be called "only if the navigation is allowed to proceed" per
  // CefMessageRouterBrowserSide::OnBeforeBrowse's own doc comment -- this
  // override never itself blocks navigation (always returns false, "allow"),
  // so that condition is always satisfied here.
  BRWPageMessageRouter::Get().OnBeforeBrowse(browser, frame);
  // browser-7z5 -- the earliest possible hook for a main-frame navigation
  // (fires before it commits), so the omnibox can show optimistic feedback
  // the instant a click/Enter registers instead of waiting for the real
  // navigation to land. Only the main frame's own navigation is the tab's
  // address; an iframe's own navigation must not touch the omnibox, same
  // guard every other per-frame delegate forward in this file already uses
  // (OnLoadStart/OnLoadEnd/OnAddressChange above).
  if (frame->IsMain() && delegate_ &&
      [delegate_ respondsToSelector:@selector(browserWillStartMainFrameNavigationTo:)]) {
    [delegate_ browserWillStartMainFrameNavigationTo:ToNSString(request->GetURL())];
  }
  return false;
}

void BRWClientHandler::OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                                  TerminationStatus status,
                                                  int error_code,
                                                  const CefString& error_string) {
  BRWPageMessageRouter::Get().OnRenderProcessTerminated(browser);
}
