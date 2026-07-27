#import "BRWMessagePump.h"

#import <AppKit/AppKit.h>

#include <climits>

#include "include/cef_app.h"

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

void BRWMessagePump::OnScheduleMessagePumpWork(int64_t delay_ms) {
  if ([NSThread isMainThread]) {
    HandleScheduleWork(delay_ms);
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    HandleScheduleWork(delay_ms);
  });
}

// Ported from MainMessageLoopExternalPump::OnScheduleWork(): a plain
// "if no timer pending, set one" implementation is not safe here because
// CefDoMessageLoopWork() can call back into this method synchronously
// (reentrantly) before returning -- see PerformMessageLoopWork().
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

  return reentrancy_detected_;
}
