// Public bridge surface between Swift/AppKit and CEF for a single browser
// tab. This header must never import a CEF header or reference a CEF type --
// it is the Swift bridging header, and the "no CEF types leak into Swift"
// rule depends on that.
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bitmask of permission kinds this app's UI actually prompts for -- a
/// small, engine-agnostic subset of CEF's own much larger permission type
/// lists (~4 media-access types plus ~29 generic prompt types; see
/// BRWClientHandler.mm's translation from cef_media_access_permission_types_t
/// / cef_permission_request_types_t). Only what browser-12m.2's scope covers:
/// camera, microphone, geolocation, notifications.
typedef NS_OPTIONS(NSUInteger, BRWPermissionKind) {
    BRWPermissionKindCamera = 1 << 0,
    BRWPermissionKindMicrophone = 1 << 1,
    BRWPermissionKindGeolocation = 1 << 2,
    BRWPermissionKindNotifications = 1 << 3,
};

/// Per-tab navigation/state callbacks, all delivered on the main thread (CEF's
/// UI thread is the main thread in this architecture -- see BRWMessagePump).
/// One BRWBrowser has at most one delegate; the Swift-side tab model owns
/// this 1:1 relationship, so events don't need to identify their source.
@protocol BRWBrowserDelegate <NSObject>
@optional
- (void)browserDidChangeTitle:(NSString *)title;
- (void)browserDidChangeURL:(NSString *)url;
- (void)browserDidChangeFaviconURL:(nullable NSString *)faviconURL;
- (void)browserDidChangeLoadingState:(BOOL)isLoading
                            canGoBack:(BOOL)canGoBack
                         canGoForward:(BOOL)canGoForward;

/// Fired once per successfully-completed top-level (main-frame) navigation --
/// i.e. a real page load, not an iframe/subresource load and not an aborted
/// or failed one (see BRWClientHandler::OnLoadEnd / OnLoadError, which
/// filters ERR_ABORTED). `url` is the frame's final settled URL, so a
/// redirect chain reports only its last hop, not each intermediate one. This
/// is the history-recording signal -- see Tab.swift / BrowserWindowController.
- (void)browserDidCommitNavigation:(NSString *)url;

/// A new download started. `destinationPath` is where CEF was told to save
/// it (see BRWClientHandler::OnBeforeDownload -- always ~/Downloads today,
/// no save dialog). `downloadId` is CEF's own globally-unique download
/// identifier, used to correlate subsequent
/// -browserDidUpdateDownloadWithId:... calls with this one.
- (void)browserDidBeginDownloadWithId:(int64_t)downloadId
                                   url:(NSString *)url
                         suggestedName:(NSString *)suggestedName
                       destinationPath:(NSString *)destinationPath;

/// Progress/state update for a download already reported via
/// -browserDidBeginDownloadWithId:.... Delivered repeatedly as bytes arrive,
/// and once more on completion/cancellation/interruption.
- (void)browserDidUpdateDownloadWithId:(int64_t)downloadId
                          receivedBytes:(int64_t)receivedBytes
                             totalBytes:(int64_t)totalBytes
                             isComplete:(BOOL)isComplete
                            isCancelled:(BOOL)isCancelled
                            isInterrupted:(BOOL)isInterrupted;

/// A page at `requestingOrigin` wants permission for `kinds` (e.g. camera
/// and microphone together, for one getUserMedia call -- CEF requires an
/// all-or-nothing answer for a bundled media request, so this is always one
/// combined ask, never split per-kind). `promptId` is opaque, unique for the
/// life of this specific request, and only for correlating with a later
/// -browserDidDismissPermissionRequest: if the request goes away before the
/// user answers (navigation, tab/browser close). Call `decision` at most
/// once, on the main thread, with YES to allow or NO to deny -- and never
/// after a matching -browserDidDismissPermissionRequest: for the same
/// `promptId`, since CEF's own underlying callback may no longer be valid
/// to invoke by then.
- (void)browserDidRequestPermission:(BRWPermissionKind)kinds
                            promptId:(uint64_t)promptId
                    requestingOrigin:(NSString *)requestingOrigin
                            decision:(void (^)(BOOL allow))decision;

/// The request identified by `promptId` (see -browserDidRequestPermission:...)
/// no longer needs an answer -- the underlying page moved on while it was
/// still pending. Any UI still showing for it should be torn down without
/// calling that request's `decision` block.
- (void)browserDidDismissPermissionRequest:(uint64_t)promptId;

/// Result update for a search started via -find:forward:matchCase:findNext:
/// (browser-5kq.5). `matchCount` is the number of matches found so far;
/// `activeMatchOrdinal` is the 1-based position of the currently highlighted
/// match (0 if there are no matches yet); `isFinalUpdate` is YES once no
/// more updates for this search will arrive. CEF delivers this repeatedly
/// (an incremental count as the page is scanned, then a final settled one),
/// not just once per search.
- (void)browserDidUpdateFindResultWithMatchCount:(int)matchCount
                              activeMatchOrdinal:(int)activeMatchOrdinal
                                     finalUpdate:(BOOL)isFinalUpdate;

/// A page called `window.cefQuery({request: ...})` via the generic JS<->
/// native message channel (browser-ojh.1's BRWPageMessageRouter). `request`
/// is exactly the string the page passed as `request` -- this bridge does
/// not interpret it; feature code on the Swift side (e.g. the password
/// manager's form-detection script) defines and parses its own payload
/// shape, typically JSON with a "type" field so unrelated features sharing
/// this one channel can tell their own messages apart. Answer at most once,
/// on the main thread, by calling -respondToPageMessageWithId:success:
/// response: with the same `requestId` -- that resolves the page's
/// `onSuccess`/`onFailure` callback. Not answering leaves the page's promise
/// pending forever (until the page itself calls `cefQueryCancel` or
/// navigates away, either of which cancels it from CEF's side with no
/// notification back to this delegate).
- (void)browserDidReceivePageMessage:(NSString *)request requestId:(int64_t)requestId;

/// Fires once per top-level (main-frame) navigation, after it has committed
/// but before the new document starts loading/running its own scripts --
/// i.e. "document-start" timing (see BRWClientHandler.mm's OnLoadStart for
/// CEF's exact guarantee). The right moment for a delegate to inject a
/// script via -executeJavaScript: that needs to run before the page's own
/// code does (browser-ojh.1's password-form-detection script is the first
/// user). Not fired for same-document navigations (fragments, history
/// state) or sub-frame loads.
- (void)browserDidStartMainFrameLoad;
@end

/// One Alloy-style CEF browser hosted inside a caller-supplied NSView, backed
/// by a CefRequestContext scoped to `profileName`. Two BRWBrowser instances
/// with different profile names have fully independent cookies/storage.
@interface BRWBrowser : NSObject

- (instancetype)initWithProfileName:(NSString *)profileName
                             hostView:(NSView *)hostView
                           initialURL:(NSString *)initialURL NS_DESIGNATED_INITIALIZER;

/// Private Browsing (browser-12m.1): backed by a brand-new CefRequestContext
/// with an empty cache_path (CEF's documented incognito mode -- see
/// BRWCreateEphemeralRequestContext's doc comment in BRWEngineInternal.h),
/// used by exactly this one browser and discarded when it closes. Distinct
/// from -initWithProfileName:hostView:initialURL: in that there is no real
/// profile identity behind it at all -- it isn't `profileName`-scoped and
/// isn't reused across windows, so two private windows never share cookies
/// or storage with each other any more than they share them with a real
/// profile.
- (instancetype)initPrivateWithHostView:(NSView *)hostView
                              initialURL:(NSString *)initialURL NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, weak, nullable) id<BRWBrowserDelegate> delegate;

- (void)loadURL:(NSString *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;

/// Requests that the browser and its underlying CEF resources close. Safe to
/// call multiple times.
- (void)close;

/// Opens Chromium DevTools for this tab. CEF pops its own separate native
/// window for it (see BRWBrowser.mm's -showDevTools for why that's the
/// right default here, rather than docking it into a view we own). Safe to
/// call while already open -- CEF just focuses the existing DevTools window
/// instead of opening a second one.
- (void)showDevTools;

/// Closes this tab's associated DevTools window, if one is open. Safe to
/// call when none is open.
- (void)closeDevTools;

/// Opens CEF's native print dialog for this tab's current page (see
/// BRWBrowser.mm's -print for what "native" actually means in this Alloy-
/// style app -- verified empirically, not assumed, per browser-5kq.6).
- (void)print;

/// Exports the current page to a PDF at `path` with default print settings
/// (letter paper, default ~1cm margins, 100% scale -- see BRWBrowser.mm's
/// -printToPDFWithPath:completion: for exactly which CefPdfPrintSettings
/// this leaves at their defaults; no UI exposes these yet). `completion` is
/// called exactly once, on the main thread, with whether it succeeded and
/// the same `path` back.
- (void)printToPDFWithPath:(NSString *)path completion:(void (^)(BOOL success, NSString *path))completion;

/// Searches the current page for `searchText` (see BRWBrowser.mm's -find:
/// for CEF's exact semantics -- changing `searchText` or `matchCase`
/// restarts the search; an empty `searchText` stops it; `findNext`
/// distinguishes a fresh search from a "find next/previous" repeat of the
/// same one). Results arrive via -browserDidUpdateFindResultWithMatchCount:
/// activeMatchOrdinal:finalUpdate: on the delegate, not as a return value or
/// completion block, since CEF delivers them asynchronously and repeatedly.
- (void)find:(NSString *)searchText forward:(BOOL)forward matchCase:(BOOL)matchCase findNext:(BOOL)findNext;

/// Cancels any in-progress search. `clearSelection` also clears the
/// highlighted-match selection on the page (YES when the user dismisses the
/// find bar; NO would leave the last match highlighted).
- (void)stopFinding:(BOOL)clearSelection;

/// Executes `code` as JavaScript in this tab's main frame, fire-and-forget.
/// CEF's public API (CefFrame::ExecuteJavaScript) has no result/completion
/// path at all -- this is genuinely one-way. Reader mode (browser-5kq.1) is
/// the current user: it injects Mozilla's Readability.js and lets the
/// injected script perform the entire extraction-and-render transformation
/// itself via `document.write`, specifically so nothing ever needs a result
/// back from this call. See docs/ai-tasks/reader-mode-notes.md.
- (void)executeJavaScript:(NSString *)code;

/// Retrieves the current page's serialized HTML source asynchronously via
/// CefFrame::GetSource (a real, native, one-shot async CEF API -- distinct
/// from -executeJavaScript:, which has no result path at all). `completion`
/// is called exactly once, on the main thread, with the source (or nil if
/// there's no ready browser/frame). Used by Reader mode to read back a
/// marker attribute injected JS sets on `<html>`, as a lightweight
/// alternative to a full CefMessageRouter round-trip for a single boolean
/// signal -- see docs/ai-tasks/reader-mode-notes.md.
- (void)getPageSourceWithCompletion:(void (^)(NSString *_Nullable source))completion;

/// Answers a page message previously delivered via
/// -browserDidReceivePageMessage:requestId: on this browser's delegate (or
/// any other browser's -- `requestId` is globally unique across the whole
/// process, not just this tab, since it's CEF's own query id). `response`
/// becomes the string the page's `onSuccess`/`onFailure` callback receives.
/// A no-op if `requestId` is no longer pending (e.g. the page already
/// navigated away and CEF canceled the query on its own).
- (void)respondToPageMessageWithId:(int64_t)requestId success:(BOOL)success response:(NSString *)response;

@end

NS_ASSUME_NONNULL_END
