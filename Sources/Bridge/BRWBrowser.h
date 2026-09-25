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

/// Where a popup/link-target browser should open, translated from CEF's own
/// cef_window_open_disposition_t (BRWClientHandler::OnBeforePopup) into
/// something that doesn't leak a CEF type into this Swift-visible header.
/// Only the subset OnBeforePopup actually needs to distinguish for tab vs.
/// window placement -- CEF's own richer enum (singleton tab, save-to-disk,
/// switch-to-tab, etc.) collapses into ForegroundTab as a safe default; see
/// BRWClientHandler.mm's translation.
typedef NS_ENUM(NSInteger, BRWWindowOpenDisposition) {
    BRWWindowOpenDispositionForegroundTab,
    BRWWindowOpenDispositionBackgroundTab,
    BRWWindowOpenDispositionNewWindow,
    BRWWindowOpenDispositionNewPopup,
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

/// Fires as soon as a main-frame navigation is *requested*, before it
/// commits (browser-7z5) -- see BRWClientHandler::OnBeforeBrowse for the
/// exact CEF timing (the earliest point CEF allows a navigation to
/// proceed). `url` is the target request's URL, not yet the tab's real
/// current one -- the intended use is optimistic UI feedback (e.g. an
/// omnibox update) shown immediately on click, not a source of truth for
/// what the tab is actually showing.
- (void)browserWillStartMainFrameNavigationTo:(NSString *)url;

/// Overall page-loading progress, 0.0-1.0 (browser-7z5) -- mirrors CEF's
/// own CefDisplayHandler::OnLoadingProgressChange directly, a real
/// percentage, not an approximation.
- (void)browserDidUpdateLoadingProgress:(double)progress;

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

/// The user chose "Look Up Image" from the native right-click context menu
/// over an `<img>` element (browser-5kq.2) -- only ever fires when
/// +[BRWBrowser setVisualLookUpAvailable:] was called with YES, since that's
/// what makes BRWClientHandler offer the menu item at all. `imageURL` is the
/// image's own source URL (a `data:` URL for an inline image, otherwise
/// whatever absolute URL the page loaded it from); `pageURL` is the
/// containing page's URL, useful as a Referer header on a follow-up fetch
/// for `imageURL` since some hosts reject image requests with no Referer.
- (void)browserDidRequestVisualLookUpForImageURL:(NSString *)imageURL pageURL:(NSString *)pageURL;

/// The user chose "Copy Image" from the native right-click context menu over
/// an `<img>` element (browser-5kq.13). `imageURL`/`pageURL` mean exactly
/// what they do for -browserDidRequestVisualLookUpForImageURL:pageURL:
/// above. Unlike that one, this fires unconditionally -- there's no
/// capability flag gating the menu item.
///
/// The delegate is expected to answer this by calling
/// -downloadImageAtURL:completion: back on the same browser rather than
/// fetching `imageURL` itself with URLSession: only the engine-side fetch
/// carries the page's own cookies (see that method's doc comment).
- (void)browserDidRequestCopyImageForImageURL:(NSString *)imageURL pageURL:(NSString *)pageURL;

/// The user chose "Copy Image Link" from the native right-click context menu
/// over an `<img>` element (browser-5kq.13) -- `imageURL` is the same
/// `GetSourceUrl()` value the two methods above report. No page URL, since
/// nothing here needs a Referer: this copies the URL string itself and
/// fetches nothing.
- (void)browserDidRequestCopyImageLinkForImageURL:(NSString *)imageURL;

/// The user chose "Download Image" from the native right-click context menu
/// over an `<img>` element (browser-5kq.14) -- `imageURL` is the same
/// `GetSourceUrl()` value the methods above report.
///
/// The delegate is expected to answer this with -startDownloadForURL: on the
/// same browser, which routes into the very same -browserDidBeginDownload...
/// pipeline a page-initiated download uses, so the saved file appears in the
/// Downloads window like any other. No page URL, since CEF derives the
/// referrer itself from the originating browser.
- (void)browserDidRequestDownloadImageForImageURL:(NSString *)imageURL;

/// The user chose "View Page Source" from the context menu -- `pageURL` is
/// `CefContextMenuParams::GetPageUrl()`.
///
/// The delegate is expected to open `view-source:<pageURL>` in a new tab.
/// This deliberately does not use `CefFrame::ViewSource()`, which writes the
/// HTML to a temp file and opens it in the user's *text editor* rather than
/// in the browser -- see BRWClientHandler's OnBeforeContextMenu, which also
/// removes CEF's own menu item pointing at it.
- (void)browserDidRequestViewSourceForPageURL:(NSString *)pageURL;

/// The engine wants `url` opened somewhere other than the current tab.
///
/// Two distinct CEF callbacks feed this, and both matter:
///
/// 1. `BRWClientHandler::OnBeforePopup` -- a target="_blank" link or
///    window.open() call, i.e. the page asking for a new browsing context,
///    which CEF would otherwise satisfy by creating its own raw native popup
///    window entirely outside this app's window management (no toolbar/tab
///    strip/session-restore/quit-sequencing integration -- see
///    BrowserWindowController). This fires *instead* of that happening.
/// 2. `BRWClientHandler::OnOpenURLFromTab` -- a Cmd-click, Cmd+Shift-click,
///    Shift-click or middle-click on an *ordinary* <a href> with no target.
///    Such a link never asks for a new browsing context, so callback (1) is
///    never consulted for it; Blink resolves the click's own modifiers into
///    a non-current-tab disposition that arrives here instead.
///
/// In both cases the reported disposition already reflects Chromium's own
/// modifier interpretation, so no live keyboard state is ever read; the
/// delegate just decides what "open" means -- a new tab in the same window for
/// *ForegroundTab/*BackgroundTab, or a genuine new native window (via this
/// app's own window-creation code) for *NewWindow/*NewPopup, matching
/// standard browser behavior for a plain target="_blank" link vs. a
/// deliberate window.open()-with-features popup (OAuth sign-in flows, etc.).
- (void)browserDidRequestNewTabForURL:(NSString *)url disposition:(BRWWindowOpenDisposition)disposition;

/// The content blocker (browser-12m.5.1) cancelled a resource request to an
/// ad/tracker domain -- see BRWClientHandler::OnBeforeResourceLoad, which
/// fires this once per blocked request. Delivered on the main thread even
/// though the underlying check runs on CEF's IO thread. The toolbar badge's
/// count (Tab.blockedRequestCount) is a running tally of these, reset on
/// each new navigation.
///
/// `trackerDomain` is the block list entry that matched, not the request's
/// own host: the list matches a domain and everything beneath it, so a
/// request to "stats.g.doubleclick.net" reports "doubleclick.net". Naming
/// the entry rather than the host is what lets the privacy report
/// (browser-e7r) count one tracker where a page used a dozen of its
/// subdomains.
///
/// `pageHost` is the host of the tab's MAIN FRAME, read on the IO thread at
/// the moment of the block rather than on the main thread when this arrives.
/// That ordering is the whole point: this callback is delivered by a hop to
/// the UI thread, so a block from the page being navigated away from can
/// land after the next page has started loading, and reading the current URL
/// on arrival would file the tracker under the wrong site. CefBrowser and
/// CefFrame are both documented callable on any thread in the browser
/// process (cef_browser.h, cef_frame.h), so capturing it early is legal as
/// well as correct. Empty for a frame with no parseable host.
- (void)browserDidBlockRequestToTracker:(NSString *)trackerDomain onPageHost:(NSString *)pageHost;
@end

/// One Alloy-style CEF browser hosted inside a caller-supplied NSView, backed
/// by a CefRequestContext scoped to `profileId`. Two BRWBrowser instances
/// with different profile ids have fully independent cookies/storage.
@interface BRWBrowser : NSObject

/// `profileId` (the profile's stable UUID) is what actually scopes the
/// on-disk CefRequestContext/cache_path (browser-ojw) -- keyed by id, not
/// name, so a later profile rename never needs to move this directory.
/// `profileName` is kept separately only for BRWClientHandler's own
/// content-blocking-settings snapshot lookup (see that class's
/// `profile_name_`), a completely different, in-memory-only, name-keyed
/// mechanism that a rename simply rebuilds fresh (see
/// ContentBlockerCoordinator's `.profileManagerDidChange` observer) --
/// don't conflate the two even though most callers have both values handy
/// at the same time.
- (instancetype)initWithProfileName:(NSString *)profileName
                            profileId:(NSString *)profileId
                             hostView:(NSView *)hostView
                           initialURL:(NSString *)initialURL NS_DESIGNATED_INITIALIZER;

/// Private Browsing (browser-12m.1): backed by a brand-new CefRequestContext
/// with an empty cache_path (CEF's documented incognito mode -- see
/// BRWCreateEphemeralRequestContext's doc comment in BRWEngineInternal.h),
/// used by exactly this one browser and discarded when it closes. Distinct
/// from -initWithProfileName:profileId:hostView:initialURL: in that there is no real
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

/// Overrides this tab's viewport to a fixed size/scale, the same effect as
/// DevTools' own device toolbar / Responsive Design Mode (browser-6hi.2) --
/// implemented via the DevTools protocol's Emulation.setDeviceMetricsOverride
/// (see BRWBrowser.mm's -setResponsiveDesignModeWithWidth:... for why this
/// doesn't require the DevTools window to be open at all: CEF documents that
/// ExecuteDevToolsMethod works without an active DevTools instance).
/// `mobile` also flips the page into "mobile" layout mode -- viewport meta
/// tag handling, matching media queries, etc. -- the same way DevTools'
/// device toolbar does when a phone/tablet preset is selected.
- (void)setResponsiveDesignModeWithWidth:(int)width
                                    height:(int)height
                         deviceScaleFactor:(double)deviceScaleFactor
                                    mobile:(BOOL)mobile
    NS_SWIFT_NAME(setResponsiveDesignMode(width:height:deviceScaleFactor:mobile:));

/// Turns off any override set by -setResponsiveDesignModeWithWidth:... --
/// safe to call even if none is currently active.
- (void)clearResponsiveDesignMode;

/// This tab's current CPU usage, as a percentage of one core (0-100 per
/// core, so a value above 100 means more than one core's worth of work --
/// see CefTaskInfo's own doc comment in cef_types.h) -- backed by CEF's
/// real CefTaskManager (browser-7jz.4), the same per-process stats engine
/// behind Chromium's own Task Manager (Shift+Esc in real Chrome). Returns
/// 0 if no task is currently tracked for this browser (e.g. its renderer
/// process hasn't finished starting yet) or if this method is called from
/// any thread other than the UI thread -- CefTaskManager's own methods are
/// documented UI-thread-only.
- (double)cpuUsagePercent;

/// Mutes/unmutes this tab's audio output (browser-rhi.4) -- wraps CEF's own
/// CefBrowserHost::SetAudioMuted, a real one-call mute confirmed present in
/// this project's pinned CEF 150.0.14 headers (cef_browser.h), contrary to
/// this task's own initial assumption that CEF's public API lacked one. No
/// JS-injection workaround needed for muting itself -- only the separate
/// "is this tab currently playing audio" indicator needs one (see
/// AudioStateScript.swift), since CEF exposes no audible-state callback.
- (void)setAudioMuted:(BOOL)muted NS_SWIFT_NAME(setAudioMuted(_:));

/// Sets this tab's page zoom (browser-5kq.15) -- wraps
/// CefBrowserHost::SetZoomLevel, a real CEF API that (unlike
/// CefBrowserHost::ExecuteChromeCommand, see the Reader mode notes) is not
/// Chrome-style-only and works on this app's Alloy-style windows.
///
/// `zoomLevel` is Chromium's *logarithmic* zoom level, not a percentage:
/// the on-screen scale factor is pow(1.2, zoomLevel), so 0 is exactly 100%,
/// 1 is 120%, -1 is ~83.3%. Callers should go through PageZoom (Swift side)
/// rather than computing levels by hand.
///
/// CEF documents this as applying immediately when called on the UI thread
/// (always the main thread in this app -- see BRWMessagePump) and
/// asynchronously otherwise.
///
/// **Scope: per host, per request context -- not per browser.** Measured, not
/// assumed (see `bd show browser-5kq.15`): this writes into Chromium's
/// HostZoomMap for the browser's current host, so calling it on one tab
/// immediately re-scales every other open tab on the same host in the same
/// profile, with no navigation involved. CEF's own doc comment says nothing
/// about this and reads as if it were per-browser. Nothing on the Swift side
/// should cache a per-tab zoom value; read it back with -zoomLevel instead.
- (void)setZoomLevel:(double)zoomLevel NS_SWIFT_NAME(setZoomLevel(_:));

/// Mirrors CefBrowserHost::GetZoomLevel -- the same logarithmic level
/// -setZoomLevel: takes, read back from the engine. UI-thread-only per CEF's
/// own doc comment (always the main thread here). Returns 0 (i.e. 100%) when
/// there's no engine-side browser yet, which is also the correct default for
/// a browser that hasn't been created.
- (double)zoomLevel;

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
/// back from this call.
- (void)executeJavaScript:(NSString *)code;

/// Retrieves the current page's serialized HTML source asynchronously via
/// CefFrame::GetSource (a real, native, one-shot async CEF API -- distinct
/// from -executeJavaScript:, which has no result path at all). `completion`
/// is called exactly once, on the main thread, with the source (or nil if
/// there's no ready browser/frame). Used by Reader mode to read back a
/// marker attribute injected JS sets on `<html>`, as a lightweight
/// alternative to a full CefMessageRouter round-trip for a single boolean
/// signal.
- (void)getPageSourceWithCompletion:(void (^)(NSString *_Nullable source))completion;

/// Answers a page message previously delivered via
/// -browserDidReceivePageMessage:requestId: on this browser's delegate (or
/// any other browser's -- `requestId` is globally unique across the whole
/// process, not just this tab, since it's CEF's own query id). `response`
/// becomes the string the page's `onSuccess`/`onFailure` callback receives.
/// A no-op if `requestId` is no longer pending (e.g. the page already
/// navigated away and CEF canceled the query on its own).
- (void)respondToPageMessageWithId:(int64_t)requestId success:(BOOL)success response:(NSString *)response;

/// Fetches and decodes the image at `imageURL` through this tab's own
/// engine-side network stack, returning PNG-encoded bytes (browser-5kq.13).
/// `completion` is called exactly once, on the main thread, with nil `pngData`
/// if the fetch or the decode failed; `httpStatusCode` is whatever the engine
/// reports (0 for a non-HTTP source such as a `data:` URL, and for some
/// early failures).
///
/// Why this exists rather than a plain URLSession fetch in the app process:
/// this wraps CefBrowserHost::DownloadImage, whose fetch is performed *by the
/// renderer*, from this browser's own request context. CEF's own header
/// spells out the consequence -- "if |is_favicon| is true then cookies are
/// not sent and not accepted during download" -- i.e. with `is_favicon`
/// false, as here, the page's cookies (and the correct initiator/referrer)
/// come along, which is the whole reason a login-gated or hotlink-protected
/// image can be copied at all. The browser cache is not bypassed, so an
/// image the page already displayed normally costs no second network request.
///
/// The result is a decoded bitmap re-encoded to PNG, not the original bytes:
/// an animated GIF yields a single still frame, and any format the engine
/// can't decode into a bitmap yields nil rather than passthrough bytes.
- (void)downloadImageAtURL:(NSString *)imageURL
                 completion:(void (^)(NSData *_Nullable pngData, NSInteger httpStatusCode))completion;

/// Starts a download of `url` originating from this tab (browser-5kq.14),
/// wrapping CefBrowserHost::StartDownload -- whose own header says it
/// downloads "using CefDownloadHandler", i.e. it arrives at the exact same
/// -browserDidBeginDownloadWithId:... / -browserDidUpdateDownloadWithId:...
/// delegate callbacks a page-initiated download does. That is the whole
/// reason this method exists rather than a private fetch-and-write: a
/// "Download Image" started here lands in DownloadStore and the Downloads
/// window with the same progress/cancel/reveal behavior as everything else.
///
/// Originating from the tab also means the request carries this profile's
/// cookies and a referrer, the same property that makes
/// -downloadImageAtURL:completion: above work on auth-gated images.
///
/// Fire-and-forget: failures (a dead URL, an unsupported scheme) surface as
/// an interrupted/cancelled download through the update callback, or as no
/// callback at all, not as a return value.
- (void)startDownloadForURL:(NSString *)url;

/// Where completed downloads are written (browser-5kq.14). Process-wide, set
/// once at launch before any browser exists; pass an empty string (or never
/// call this) for the default `~/Downloads`, which is what every launch that
/// isn't an isolated `--profiles-root` test gets. See
/// BrowserCore's ProfilesRootResolver.downloadsDirectory for the resolution
/// rule, and BRWClientHandler::SetDownloadDirectory for why it lives beside
/// the visual-look-up flag rather than on a per-browser instance.
+ (void)setDownloadDirectory:(NSString *)directory;

/// Process-wide (not per-browser), since whether Visual Look Up can work at
/// all is a Mac hardware/OS capability (Swift-side ImageAnalyzer.isSupported,
/// browser-5kq.2), not something that varies by tab. Call once at launch
/// with the actual support state -- every BRWClientHandler checks this same
/// flag before offering "Look Up Image" in its context menu, so a browser
/// created before this is called (unlikely in practice; call it during app
/// launch, before any window opens) simply wouldn't offer the item until a
/// later navigation's next right-click, which re-checks the flag fresh each
/// time rather than caching it per-handler.
+ (void)setVisualLookUpAvailable:(BOOL)available;

@end

NS_ASSUME_NONNULL_END
