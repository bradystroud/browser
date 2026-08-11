#import "BRWClientHandler.h"
#import "BRWContentBlockerInternal.h"
#import "BRWPageMessageRouter.h"
#import "BRWThreatListInternal.h"

#include <vector>

#include "include/cef_parser.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_helpers.h"

namespace {
NSString* ToNSString(const CefString& s) {
  return [NSString stringWithUTF8String:s.ToString().c_str()];
}

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

  if (delegate_ && [delegate_ respondsToSelector:@selector(browserDidRequestNewTabForURL:disposition:)]) {
    [delegate_ browserDidRequestNewTabForURL:ToNSString(target_url)
                                 disposition:TranslateDisposition(target_disposition)];
    // Cancel the source browser's own navigation -- the delegate is opening
    // this URL somewhere else.
    return true;
  }
  return false;
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
  if (delegate_ && [delegate_ respondsToSelector:@selector(browserDidStartMainFrameLoad)]) {
    [delegate_ browserDidStartMainFrameLoad];
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
}  // namespace

// static
bool BRWClientHandler::visual_look_up_available_ = false;

void BRWClientHandler::OnBeforeContextMenu(CefRefPtr<CefBrowser> browser,
                                             CefRefPtr<CefFrame> frame,
                                             CefRefPtr<CefContextMenuParams> params,
                                             CefRefPtr<CefMenuModel> model) {
  if (!params->HasImageContents()) {
    // Every item this handler adds is about the right-clicked image, so a
    // right-click on anything else (text, a link, the page background)
    // leaves CEF's own default menu completely untouched.
    return;
  }
  if (model->GetCount() > 0) {
    model->AddSeparator();
  }
  // Copy Image / Copy Image Link are unconditional (browser-5kq.13); "Look
  // Up Image" additionally needs the Mac to support VisionKit analysis at
  // all (browser-5kq.2), so it can be absent while the other two are there.
  model->AddItem(kCopyImageCommandId, "Copy Image");
  model->AddItem(kCopyImageLinkCommandId, "Copy Image Link");
  if (visual_look_up_available_) {
    model->AddItem(kVisualLookUpCommandId, "Look Up Image");
  }
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
  if (BRWContentBlockerShouldBlock(profile_name_, host)) {
    // Report the block back to the delegate so the toolbar badge
    // (Tab.blockedRequestCount) actually reflects it -- delegate_ is only
    // safe to message on the UI thread, but reading a __weak reference
    // itself is thread-safe (internally synchronized), so promote to a
    // strong local here on the IO thread and hop to UI to deliver it, same
    // pattern as the continue-marker/threat-list branches above.
    id<BRWBrowserDelegate> strong_delegate = delegate_;
    if (strong_delegate) {
      CefPostTask(TID_UI, new BRWBlockTask(^{
        [strong_delegate browserDidBlockRequest];
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
      CefPostTask(TID_UI, new BRWBlockTask(^{
        if (!target_frame || !target_frame->IsValid()) {
          return;
        }
        const std::string interstitial_url = BRWThreatListBuildInterstitialURL(target_host, blocked_url);
        if (!interstitial_url.empty()) {
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
