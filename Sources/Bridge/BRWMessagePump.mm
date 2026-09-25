#import "BRWMessagePump.h"

#import <AppKit/AppKit.h>

#include <climits>

#include "include/cef_app.h"

#import "BRWEngine.h"

namespace {
// Special timer delay placeholder value, matching CEF's own reference
// implementation: signals "schedule the maximum allowed delay" without
// clobbering a shorter timer that's already pending.
constexpr int32_t kTimerDelayPlaceholder = INT_MAX;

// Never wait longer than this between CefDoMessageLoopWork() calls (30fps
// ceiling), matching CEF's own sample apps.
constexpr int64_t kMaxTimerDelayMs = 1000 / 30;
}  // namespace

@interface BRWMessagePumpTimerOwner : NSObject
@property(nonatomic, assign) BRWMessagePump* pump;
@property(nonatomic, strong, nullable) NSTimer* timer;
- (void)fire:(NSTimer*)timer;
@end

@implementation BRWMessagePumpTimerOwner {
}
@synthesize pump = _pump;
@synthesize timer = _timer;

- (void)fire:(NSTimer *)timer {
  self.timer = nil;
  if (self.pump) {
    self.pump->OnScheduleMessagePumpWork(0);
  }
}
@end

BRWMessagePump& BRWMessagePump::Get() {
  static BRWMessagePump instance;
  return instance;
}

BRWMessagePump::BRWMessagePump() {
  BRWMessagePumpTimerOwner* owner = [[BRWMessagePumpTimerOwner alloc] init];
  owner.pump = this;
  timer_owner_ = (__bridge_retained void*)owner;
}

BRWMessagePump::~BRWMessagePump() {
  BRWMessagePumpTimerOwner* owner = (__bridge_transfer BRWMessagePumpTimerOwner*)timer_owner_;
  [owner.timer invalidate];
}

// CEF's own Mac reference implementation
// (tests/shared/browser/main_message_loop_external_pump_mac.mm) marshals
// EVERY call here through
// `[event_handler_ performSelector:@selector(scheduleWork:) onThread:...
// waitUntilDone:NO]` -- unconditionally, even when already called from the
// owner thread. That unconditional hop to a fresh run-loop turn is
// load-bearing, not a thread-hop convenience: OnScheduleMessagePumpWork can
// be invoked by CEF synchronously from other CEF entry points that are still
// executing on the calling thread's own stack and haven't returned yet --
// CefFrame::LoadURL is a confirmed example: calling it from an omnibox
// action triggers this callback before LoadURL itself returns. This port's first version
// special-cased "already on the main thread" to call HandleScheduleWork
// (and thus potentially CefDoMessageLoopWork()) inline -- skipping exactly
// the deferral the reference always performs -- which reenters CEF's
// internals from a call stack CEF isn't expecting to be reentered from, and
// deadlocks: confirmed via `sample`, the main thread blocks forever on a
// pthread mutex held by another thread that is itself waiting on the main
// thread to finish LoadURL and return to the run loop.
void BRWMessagePump::OnScheduleMessagePumpWork(int64_t delay_ms) {
  dispatch_async(dispatch_get_main_queue(), ^{
    HandleScheduleWork(delay_ms);
  });
}

// Ported from MainMessageLoopExternalPump::OnScheduleWork(). Safe to call
// DoWork() synchronously/inline for delay_ms<=0 here, matching the
// reference exactly: by the time this runs, OnScheduleMessagePumpWork above
// has already unconditionally hopped to a fresh run-loop turn, so this
// never executes nested inside whatever CEF call originally triggered the
// schedule request. PerformMessageLoopWork()'s is_active_ guard remains for
// the separate, narrower case this method's own reentrancy comment
// describes (CefDoMessageLoopWork() calling back into this method before
// returning).
void BRWMessagePump::HandleScheduleWork(int64_t delay_ms) {
  BRWMessagePumpTimerOwner* owner = (__bridge BRWMessagePumpTimerOwner*)timer_owner_;

  if (delay_ms == kTimerDelayPlaceholder && owner.timer != nil) {
    // Don't clobber a shorter timer that's already pending with the
    // "whenever, no rush" placeholder requested from DoWork().
    return;
  }

  [owner.timer invalidate];
  owner.timer = nil;

  if (delay_ms <= 0) {
    DoWork();
    return;
  }

  if (delay_ms > kMaxTimerDelayMs) {
    delay_ms = kMaxTimerDelayMs;
  }

  NSTimer* timer = [NSTimer timerWithTimeInterval:(double)delay_ms / 1000.0
                                            target:owner
                                          selector:@selector(fire:)
                                          userInfo:nil
                                           repeats:NO];
  owner.timer = timer;
  // Common + event-tracking modes so CEF keeps pumping while the user is
  // resizing a window or tracking a menu.
  [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
  [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSEventTrackingRunLoopMode];
}

void BRWMessagePump::DoWork() {
  const bool was_reentrant = PerformMessageLoopWork();
  BRWMessagePumpTimerOwner* owner = (__bridge BRWMessagePumpTimerOwner*)timer_owner_;
  if (was_reentrant) {
    // More work arrived while we were pumping; do it as soon as possible.
    OnScheduleMessagePumpWork(0);
  } else if (owner.timer == nil) {
    // Schedule a ceiling timer so CEF gets pumped at least at kMaxTimerDelayMs
    // even if nothing else asks for work. May be dropped above if a shorter
    // timer is already in flight by the time this executes.
    OnScheduleMessagePumpWork(kTimerDelayPlaceholder);
  }
}

// Ported from MainMessageLoopExternalPump::PerformMessageLoopWork(): guards
// against CefDoMessageLoopWork() re-entrantly triggering another call to this
// same method (via a nested OnScheduleMessagePumpWork with delay_ms<=0)
// before the first call has returned -- calling CefDoMessageLoopWork() from
// inside itself is unsafe, so a reentrant request is deferred instead.
bool BRWMessagePump::PerformMessageLoopWork() {
  if (is_active_) {
    reentrancy_detected_ = true;
    return false;
  }

  reentrancy_detected_ = false;
  is_active_ = true;
  CefDoMessageLoopWork();
  is_active_ = false;

  // This is the one place every real CefDoMessageLoopWork() tick lands, so
  // it's the only place +[BRWEngine requestShutdownWithCompletion:]'s "every browser closed
  // yet?" poll can actually observe an OnBeforeClose that just arrived.
  [BRWEngine checkShutdownCompletion];

  return reentrancy_detected_;
}
