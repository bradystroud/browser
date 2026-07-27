// NSApplication subclass required by CEF's macOS integration: CEF needs to
// know when it is inside -sendEvent: (via CefAppProtocol) so that Chromium's
// event-tracking loops (menu tracking, drag sessions, etc.) interleave
// correctly with the external message pump. This class has no CEF types in
// its header, so it is safe to expose to Swift via the bridging header.
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface BRWApplication : NSApplication
/// Forces NSApp to become a BRWApplication instance. Must be called before
/// any other NSApplication.shared access (i.e. first thing in main.swift).
+ (void)bootstrap;
@end

NS_ASSUME_NONNULL_END
