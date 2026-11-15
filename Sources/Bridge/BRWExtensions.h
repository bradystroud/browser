// Public bridge surface for Chromium's own extension system in CEF tabs.
// This header must never import a CEF header or reference a CEF type -- it is
// part of the Swift bridging header, like BRWEngine.h and BRWBrowser.h.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Answers one extension-bridge request. Call it at most once, from any
/// thread. YES sends HTTP 200 with `replyJSON` as the body ("null" when nil);
/// NO sends HTTP 400 with `replyJSON` (or `{"error":"rejected"}` when nil).
/// The body is sent as given, so it must already be JSON. A call after the
/// request timed out, or after the extension's fetch went away, does nothing.
typedef void (^BRWExtensionBridgeReply)(BOOL success, NSString *_Nullable replyJSON);

/// Receives what Chromium's extension runtime asks of the app. Every method
/// runs on the main thread.
@protocol BRWExtensionRuntimeDelegate <NSObject>

/// An extension sent a request over the bridge channel: a `fetch` POST to
/// `<+bridgeOrigin>/v1/<kind>` with a JSON body, from the extension's own
/// service worker or one of its own pages. The bridge accepts it only when
/// Chromium reports the request's initiator as `chrome-extension://<id>`, and
/// only in a profile's own request context, never a private one.
///
/// `extensionId` comes from that initiator, never from the payload, and
/// `profileId` is the profile id whose context made the request (the id
/// BRWBrowser was created with). Both are trustworthy; nothing inside
/// `payloadJSON` is. `kind` is 1-64 characters of `[A-Za-z0-9._-]`.
/// `payloadJSON` is the request body, already checked to be valid JSON.
///
/// The extension's fetch waits for `reply`. If it is not called within
/// +requestTimeout, the bridge answers HTTP 504 itself.
- (void)extensionRuntimeDidReceiveRequestWithKind:(NSString *)kind
                                      extensionId:(NSString *)extensionId
                                        profileId:(NSString *)profileId
                                      payloadJSON:(NSString *)payloadJSON
                                            reply:(BRWExtensionBridgeReply)reply
    NS_SWIFT_NAME(extensionRuntimeDidReceiveRequest(kind:extensionId:profileId:payloadJSON:reply:));

@optional

/// Chromium created a Chrome-style browser window of its own (extension code
/// such as `windows.create`, `runtime.openOptionsPage` or an interactive
/// `identity.launchWebAuthFlow` that got past the shim). The bridge has
/// already closed it, and its first navigation never loaded. `url` is the
/// page it was opening, or nil when it was blank or never named one;
/// `profileId` is the profile whose context it belonged to, or nil when it
/// was a context no profile owns (Chromium's own default context). The app
/// may open `url` as its own tab; nothing has opened it yet.
- (void)extensionRuntimeDidCloseUnmanagedBrowserWithURL:(nullable NSString *)url
                                              profileId:(nullable NSString *)profileId
    NS_SWIFT_NAME(extensionRuntimeDidCloseUnmanagedBrowser(url:profileId:));

/// A profile's request context finished initializing: CEF's
/// OnRequestContextInitialized. Chromium has already read the
/// `load-extension` folders for that profile by then, synchronously, so
/// whatever folders were present at that moment are the ones it loaded, and
/// changing them now cannot affect it. Sent once per context, whether it was
/// created by +initializeProfileContextWithId:completion: or by the
/// profile's first tab.
- (void)extensionRuntimeProfileContextDidInitialize:(NSString *)profileId
    NS_SWIFT_NAME(extensionRuntimeProfileContextDidInitialize(profileId:));

@end

/// Process-wide set-up for Chromium's extension runtime in CEF tabs.
@interface BRWExtensionRuntime : NSObject

/// The extension folders to load into every profile's request context, as
/// Chromium's `load-extension` switch. Call before
/// +[BRWEngine initializeWithProfilesRootPath:]; Chromium reads the switch
/// once, so a later call changes nothing and returns NO. A folder already
/// named by a `--load-extension` on the app's own command line is kept only
/// when +setKeepsExternalExtensionSwitches: allowed it, and these are added
/// after it. A path containing a comma is skipped and
/// logged, because Chromium splits the switch on commas. Main thread only.
+ (BOOL)setLoadExtensionPaths:(NSArray<NSString *> *)paths NS_SWIFT_NAME(setLoadExtensionPaths(_:));

/// Whether extension switches on the app's own command line that the app did
/// not add (`--load-extension`, `--disable-extensions-except`,
/// `--enable-unsafe-extension-debugging`, `--extension-*`, `--extensions-*`)
/// are kept. NO by default: they are removed, with a log line, so nothing
/// that launches the app can load an unvetted extension into the user's real
/// profiles. Pass YES for a development or scratch launch, where tests rely
/// on them. Call before +[BRWEngine initializeWithProfilesRootPath:]; returns
/// NO, changing nothing, after. Main thread only.
+ (BOOL)setKeepsExternalExtensionSwitches:(BOOL)keep NS_SWIFT_NAME(setKeepsExternalExtensionSwitches(_:));

/// Where bridge requests go, set before any extension can send one. Weak.
/// While it is nil every request is answered HTTP 503. Main thread only.
@property (class, nonatomic, weak, nullable) id<BRWExtensionRuntimeDelegate> delegate;

/// How long a bridge request waits for its reply before the bridge answers
/// HTTP 504 itself. Default 10 seconds. Main thread only.
@property (class, nonatomic) NSTimeInterval requestTimeout;

/// The reserved origin of the bridge channel,
/// `https://extension-bridge.browser.invalid`, without a trailing slash.
/// No request to it ever reaches the network.
@property (class, nonatomic, readonly) NSString *bridgeOrigin;

/// Creates `profileId`'s request context now, before its first tab, and runs
/// `completion` on the main thread once it has initialized (see
/// -extensionRuntimeProfileContextDidInitialize:). When it has already
/// initialized, `completion` still runs, asynchronously. Contexts are
/// created asynchronously, and each one reads the `load-extension` folders
/// at an uncontrolled moment before it initializes: to control which
/// folders a profile sees, create one context at a time and wait for this
/// completion before changing the folders or creating the next. Call after
/// +[BRWEngine initializeWithProfilesRootPath:] has returned. Main thread
/// only.
+ (void)initializeProfileContextWithId:(NSString *)profileId
                            completion:(nullable void (^)(void))completion
    NS_SWIFT_NAME(initializeProfileContext(id:completion:));

/// Whether `profileId`'s context has sent its initialized signal. Main thread
/// only.
+ (BOOL)isProfileContextInitialized:(NSString *)profileId;

/// YES once CEF's global context, and with it Chromium's own initial profile
/// (the root `Default` one no app tab uses), has initialized. That profile
/// also reads the `load-extension` folders. CEF reports this from inside
/// +[BRWEngine initializeWithProfilesRootPath:], so it is already YES when
/// that returns. Main thread only.
@property (class, nonatomic, readonly) BOOL engineContextInitialized;

@end

NS_ASSUME_NONNULL_END
