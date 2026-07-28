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
@end

/// One Alloy-style CEF browser hosted inside a caller-supplied NSView, backed
/// by a CefRequestContext scoped to `profileName`. Two BRWBrowser instances
/// with different profile names have fully independent cookies/storage.
@interface BRWBrowser : NSObject

- (instancetype)initWithProfileName:(NSString *)profileName
                             hostView:(NSView *)hostView
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

@end

NS_ASSUME_NONNULL_END
