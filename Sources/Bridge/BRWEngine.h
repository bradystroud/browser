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
/// by CEF (see docs/research/2026-07-27-cef-swift-architecture.md).
+ (BOOL)initializeWithProfilesRootPath:(NSString *)profilesRootPath;

/// Pumps the CEF message loop. The caller integrates this with its own run
/// loop (e.g. an NSTimer firing in common run loop modes); CEF is configured
/// with external_message_pump so it never spins its own loop.
+ (void)doMessageLoopWork;

/// Runs CefShutdown. Call after all browsers are closed and before process exit.
+ (void)shutdown;

@end

/// One Alloy-style CEF browser hosted inside a caller-supplied NSView, backed
/// by a CefRequestContext scoped to `profileName`. Two BRWBrowser instances
/// with different profile names have fully independent cookies/storage.
@interface BRWBrowser : NSObject

- (instancetype)initWithProfileName:(NSString *)profileName
                             hostView:(NSView *)hostView
                           initialURL:(NSString *)initialURL NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)loadURL:(NSString *)url;

/// Requests that the browser and its underlying CEF resources close. Safe to
/// call multiple times.
- (void)close;

@end

NS_ASSUME_NONNULL_END
