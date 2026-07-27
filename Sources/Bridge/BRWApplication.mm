#import "BRWApplication.h"

#include "include/cef_application_mac.h"

@interface BRWApplication () <CefAppProtocol> {
  BOOL _handlingSendEvent;
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

// Requesting secure restorable state avoids macOS re-restoring windows
// incorrectly after a hard reset, and is required on macOS 12+.
- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
  return YES;
}

@end
