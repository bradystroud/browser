// Internal C++ interface -- never exposed to Swift. Bridges CEF's external
// message pump (CefSettings.external_message_pump = true,
// multi_threaded_message_loop = false) onto an NSTimer driven by AppKit's own
// run loop, so CEF piggybacks on the app's main run loop instead of owning
// it. Scheduling algorithm ported from CEF's own reference implementation
// (tests/shared/browser/main_message_loop_external_pump.cc in the CEF
// distribution) -- the reentrancy handling here is load-bearing, not
// decorative: CefDoMessageLoopWork() can synchronously trigger another
// OnScheduleMessagePumpWork() call before it returns, and calling
// CefDoMessageLoopWork() again from inside itself is unsafe.
#pragma once

#include <cstdint>

class BRWMessagePump {
 public:
  static BRWMessagePump& Get();

  // May be called from any CEF thread; hops to the main thread internally.
  void OnScheduleMessagePumpWork(int64_t delay_ms);

  BRWMessagePump(const BRWMessagePump&) = delete;
  BRWMessagePump& operator=(const BRWMessagePump&) = delete;

 private:
  BRWMessagePump();
  ~BRWMessagePump();

  void HandleScheduleWork(int64_t delay_ms);
  void HandleTimerTimeout();
  void DoWork();
  bool PerformMessageLoopWork();

  // Opaque pointer to an Objective-C helper object owning the NSTimer;
  // kept out of this header so it stays includable from plain C++.
  void* timer_owner_;

  bool is_active_ = false;
  bool reentrancy_detected_ = false;
};
