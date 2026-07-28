// Public bridge surface between Swift/AppKit and CEF for phishing/malware
// warnings (browser-12m.6). This header must never import a CEF header or
// reference a CEF type -- it is the Swift bridging header, and the "no CEF
// types leak into Swift" rule depends on that. Deliberately parallel to,
// and separate from, BRWContentBlocker.h (the ad/tracker case): a threat
// hit gets different treatment (an interstitial the user can click
// through) than an ad hit (a silent cancel), so it gets its own snapshot
// and settings type rather than reusing BRWContentBlocker's.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One profile's threat-warning configuration, mirroring Swift's
/// ThreatWarningSettings (BlockListCore) -- a thin value carrier across the
/// bridge boundary, same role as BRWProfileBlockingSettings plays for the
/// ad/tracker case.
@interface BRWProfileThreatSettings : NSObject

- (instancetype)initWithEnabled:(BOOL)enabled NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

/// Receives a flattened threat-list snapshot from Swift, and the Swift-side
/// interstitial-page builder, for BRWClientHandler::OnBeforeResourceLoad to
/// read/call on CEF's IO thread. See BRWThreatList.mm's class-level comment
/// for the threading model (the (domains, profile-settings) snapshot uses
/// the exact same atomic-swap technique as BRWContentBlocker.mm).
@interface BRWThreatList : NSObject

/// Same contract as +[BRWContentBlocker updateWithBlockedDomains:
/// profileSettings:] -- call from the main thread at launch (after loading
/// the starter threat list) and any time the Privacy pane's "Warn about
/// dangerous sites" toggle changes for a profile.
+ (void)updateWithThreatDomains:(NSArray<NSString *> *)threatDomains
                  profileSettings:(NSDictionary<NSString *, BRWProfileThreatSettings *> *)profileSettings;

/// Registers the Swift closure that renders a blocked-navigation warning
/// page -- a data: URL (see ThreatWarningPageRenderer in BlockListCore,
/// which reuses StartPageRenderer's own data:-URL technique) -- for a given
/// host and the original URL that was blocked. Call once, from the main
/// thread, before any browser can navigate (see ThreatListCoordinator.start()).
/// The block itself is only ever invoked later from CEF's UI thread -- which
/// is this app's main thread (external message pump, single-threaded, see
/// BRWBrowser.h's own note on that) -- so it's safe for it to touch ordinary
/// Swift/Foundation state.
+ (void)setInterstitialPageBuilder:(NSString * (^)(NSString *host, NSString *originalURL))builder;

@end

NS_ASSUME_NONNULL_END
