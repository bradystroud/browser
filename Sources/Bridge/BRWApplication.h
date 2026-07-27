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

/// Also overrides -terminate: (the single entry point behind Cmd+Q, the Quit
/// menu item, Dock menu Quit, and logout/restart/shutdown) to sequence CEF's
/// required shutdown -- close every browser, wait for CEF to confirm, only
/// then exit -- instead of letting AppKit's default -terminate: tear the
/// process down immediately. See the .mm file for why this can't be done via
/// NSApplicationDelegate's -applicationShouldTerminate:.
@end

NS_ASSUME_NONNULL_END
