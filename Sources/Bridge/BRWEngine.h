// Public bridge surface between Swift/AppKit and CEF. This header must never
// import a CEF header or reference a CEF type -- it is the Swift bridging
// header, and the "no CEF types leak into Swift" rule depends on that.
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Process-wide CEF lifecycle. Call Initialize once from the browser
/// process's main() before creating any BRWBrowser, and Shutdown once at exit
/// (after all BRWBrowser instances have been closed).
@interface BRWEngine : NSObject

/// Runs CefInitialize. `profilesRootPath` becomes CefSettings.root_cache_path;
/// every profile's cache_path is a child directory of this path, as required
/// by CEF (it crashes otherwise).
+ (BOOL)initializeWithProfilesRootPath:(NSString *)profilesRootPath;

/// Checked by BRWMessagePump after every real CefDoMessageLoopWork() tick
/// (the only place CEF's close/OnBeforeClose callbacks actually get
/// delivered): fires +requestShutdownWithCompletion:'s completion once every
/// browser has confirmed closed. Not for any other caller.
+ (void)checkShutdownCompletion;

/// Runs CefShutdown. CEF crashes (EXC_BREAKPOINT) if this runs while any
/// CefBrowser is still alive -- callers must go through
/// +requestShutdownWithCompletion: instead, which guarantees that ordering.
/// Exposed only for that method's own use once every browser has closed.
+ (void)shutdown;

/// Registers the block the Swift app layer uses to close every window it
/// owns -- WindowManager.shared's Swift-side NSWindow/BrowserWindowController/
/// Tab objects, which this bridge has no visibility into otherwise. Call once
/// at launch (after +initializeWithProfilesRootPath: succeeds).
/// +requestShutdownWithCompletion: invokes this synchronously, before it
/// force-closes any browser itself, so that quitting tears down the same
/// Swift objects (and, through their normal close path, the same CefBrowsers)
/// a single window's ordinary close button would -- see that method's doc
/// comment for why leaving them alive is a crash, not just a leak.
+ (void)setWindowCloseHandler:(void (^)(void))handler;

/// Begins process-wide app termination: first invokes the block registered
/// via +setWindowCloseHandler: (synchronously closing every Swift-owned
/// window, which closes its tabs' BRWBrowsers through their normal path),
/// then force-closes any BRWBrowser that's still open regardless -- CEF's
/// CreateBrowser is asynchronous, so a browser requested moments before
/// quitting can still be pre-OnAfterCreated and thus untouched by the normal
/// per-tab close path; see BRWClientHandler::CloseAll()'s pending_close_
/// handling for that case specifically. Then waits for CEF's required
/// OnBeforeClose callback from every browser (delivered via the ongoing
/// BRWMessagePump ticks), runs CefShutdown, and invokes `completion` on
/// the main thread. Safe to call with zero open browsers, and safe to call
/// with no window-close handler registered. This is the only supported way
/// to shut CEF down.
///
/// The caller must return control to the normal NSApplication run loop
/// immediately after calling this (rather than blocking, or handing control
/// to any nested/private AppKit event-loop mode such as the one
/// -applicationShouldTerminate:'s NSTerminateLater triggers) so that
/// BRWMessagePump keeps getting ticked -- see -[BRWApplication
/// terminate:], the only supported caller.
+ (void)requestShutdownWithCompletion:(void (^)(void))completion;

@end

NS_ASSUME_NONNULL_END
