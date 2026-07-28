// Public bridge surface between Swift/AppKit and CEF for content blocking.
// This header must never import a CEF header or reference a CEF type -- it
// is the Swift bridging header, and the "no CEF types leak into Swift" rule
// depends on that.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One profile's content-blocking configuration, mirroring Swift's
/// BlockingSettings (BlockListCore) -- a thin value carrier across the
/// bridge boundary, nothing more. Swift owns the real model (Codable,
/// persisted, validated); this only exists so BRWContentBlocker can receive
/// it.
@interface BRWProfileBlockingSettings : NSObject

- (instancetype)initWithEnabled:(BOOL)enabled
                allowlistedHosts:(NSArray<NSString *> *)allowlistedHosts NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

/// Receives a flattened content-blocker snapshot from Swift and publishes it
/// for BRWClientHandler::OnBeforeResourceLoad to read on CEF's IO thread.
/// See BRWContentBlocker.mm's class-level comment for the full atomic-swap
/// threading model (no locks on the actual per-request lookup).
@interface BRWContentBlocker : NSObject

/// Call from the main thread whenever the shared block list or any
/// profile's BlockingSettings changes -- app launch (after loading the
/// starter list), and any time the Settings window's Privacy pane edits a
/// profile's settings. `blockedDomains` is every domain in the shared
/// BlockList (see BlockList.allDomains()); `profileSettings` maps profile
/// name -> that profile's current settings. Builds a brand-new immutable
/// snapshot and atomically publishes it; a resource-load check already in
/// flight on the IO thread keeps using whichever snapshot it already read,
/// old or new, never a partially-updated one.
+ (void)updateWithBlockedDomains:(NSArray<NSString *> *)blockedDomains
                  profileSettings:(NSDictionary<NSString *, BRWProfileBlockingSettings *> *)profileSettings;

@end

NS_ASSUME_NONNULL_END
