#import "BRWApplication.h"

#include "include/cef_application_mac.h"

#import "BRWEngine.h"

@interface BRWApplication () <CefAppProtocol> {
  BOOL _handlingSendEvent;
  BOOL _isTerminating;
}
@end

@implementation BRWApplication

+ (void)bootstrap {
  [BRWApplication sharedApplication];
}

- (BOOL)isHandlingSendEvent {
  return _handlingSendEvent;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  _handlingSendEvent = handlingSendEvent;
}

- (void)sendEvent:(NSEvent *)event {
  CefScopedSendingEvent sendingEventScoper;
  [super sendEvent:event];
}

// browser-2ji diagnostics hook. Every self-activation this app performs goes
// through -activateIgnoringOtherApps: (that is what Swift's
// NSApp.activate(ignoringOtherApps:) compiles to, at all eight call sites),
// so overriding it here is the only place a "did *we* pull ourselves back to
// the front?" signal can be observed at all -- the app-level
// didBecomeActiveNotification fires identically whether the user clicked our
// Dock icon or we asked for focus ourselves, and cannot tell the two apart.
//
// The call stack is captured here, synchronously, and handed over in
// userInfo: the observer is delivered on the main queue, by which point the
// frames that requested the activation have already returned.
//
// Posting unconditionally is deliberate -- FocusDiagnostics ignores this
// unless its marker file is present, and gating it here instead would mean
// the hook is only live for launches that already knew to enable it.
- (void)activateIgnoringOtherApps:(BOOL)flag {
  [[NSNotificationCenter defaultCenter]
      postNotificationName:@"AppActivationRequestedNotification"
                    object:self
                  userInfo:@{@"callStack" : [NSThread callStackSymbols]}];
  [super activateIgnoringOtherApps:flag];
}

// Requesting secure restorable state avoids macOS re-restoring windows
// incorrectly after a hard reset, and is required on macOS 12+.
- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
  return YES;
}

// -terminate: is Cocoa's single entry point for every orderly quit: Cmd+Q,
// the app/Dock menu's Quit item, "Quit" (not "Force Quit") in Activity
// Monitor, and quits triggered by logout/restart/shutdown. The default
// implementation ends the process (effectively exit()) wherever it happens
// to be called from, which would tear down the process while CefBrowser
// instances -- and their in-flight IPC to the renderer/GPU processes -- are
// still alive. CEF requires every browser to be closed, and its
// OnBeforeClose callback delivered, before CefShutdown runs; skipping that
// is exactly the EXC_BREAKPOINT this override exists to prevent (see
// +[BRWEngine requestShutdownWithCompletion:]).
//
// This does NOT use NSApplicationDelegate's -applicationShouldTerminate:
// returning .terminateLater: that makes AppKit spin its own internal event
// loop (a private run-loop mode) while waiting for
// -replyToApplicationShouldTerminate:, and that internal loop never services
// the run-loop timer BRWMessagePump relies on to keep ticking CEF's external
// message pump -- so OnBeforeClose is never delivered and the app hangs
// forever instead of quitting (confirmed via `sample`: the main thread
// blocks in mach_msg inside -[NSApplication _shouldTerminate] indefinitely).
// CEF's own reference apps (tests/cefclient, tests/cefsimple) hit this same
// incompatibility and override -terminate: for the same reason -- see their
// mac.mm files' -terminate: doc comments.
- (BOOL)isTerminating {
  return _isTerminating;
}

- (void)terminate:(id)sender {
  if (_isTerminating) {
    return;  // A second Cmd+Q (or Quit + logout) while already quitting.
  }
  _isTerminating = YES;

  [BRWEngine requestShutdownWithCompletion:^{
    exit(0);
  }];
  // Return, don't exit -- the completion above exits once CEF confirms every
  // browser has actually finished closing.
}

@end
