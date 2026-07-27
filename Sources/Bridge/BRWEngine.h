// Public bridge surface between Swift/AppKit and CEF. This header must never
// import a CEF header or reference a CEF type -- it is the Swift bridging
// header, and the "no CEF types leak into Swift" rule depends on that.
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

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
@end

/// Process-wide CEF lifecycle. Call Initialize once from the browser
/// process's main() before creating any BRWBrowser, and Shutdown once at exit
/// (after all BRWBrowser instances have been closed).
@interface BRWEngine : NSObject

/// Runs CefInitialize. `profilesRootPath` becomes CefSettings.root_cache_path;
/// every profile's cache_path is a child directory of this path, as required
/// by CEF (see docs/research/2026-07-27-cef-swift-architecture.md).
+ (BOOL)initializeWithProfilesRootPath:(NSString *)profilesRootPath;

/// Pumps the CEF message loop. The caller integrates this with its own run
/// loop (e.g. an NSTimer firing in common run loop modes); CEF is configured
/// with external_message_pump so it never spins its own loop.
+ (void)doMessageLoopWork;

/// Runs CefShutdown. CEF crashes (EXC_BREAKPOINT) if this runs while any
/// CefBrowser is still alive -- callers must go through
/// +requestShutdownWithCompletion: instead, which guarantees that ordering.
/// Exposed only for that method's own use once every browser has closed.
+ (void)shutdown;

/// Begins process-wide app termination: force-closes every open BRWBrowser,
/// waits for CEF's required OnBeforeClose callback from each (delivered via
/// the ongoing +doMessageLoopWork pump), then runs CefShutdown and invokes
/// `completion` on the main thread. Safe to call with zero open browsers.
/// This is the only supported way to shut CEF down.
///
/// The caller must return control to the normal NSApplication run loop
/// immediately after calling this (rather than blocking, or handing control
/// to any nested/private AppKit event-loop mode such as the one
/// -applicationShouldTerminate:'s NSTerminateLater triggers) so that
/// +doMessageLoopWork keeps getting ticked -- see -[BRWApplication
/// terminate:], the only supported caller.
+ (void)requestShutdownWithCompletion:(void (^)(void))completion;

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

@end

NS_ASSUME_NONNULL_END
