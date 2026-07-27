#import "BRWCefApp.h"

#import "BRWMessagePump.h"

BRWCefApp::BRWCefApp() = default;

void BRWCefApp::OnBeforeCommandLineProcessing(
    const CefString& process_type,
    CefRefPtr<CefCommandLine> command_line) {
  // Ad-hoc-signed local builds have no stable Team ID, so the OS treats every
  // launch as a different app for Keychain ACL purposes: Chromium's OSCrypt
  // "Chromium Safe Storage" item would prompt a (secure-input, unautomatable)
  // keychain dialog on first cookie access for every profile, every launch.
  // Mock keychain sidesteps that for local dev. Once this ships with a real
  // Developer ID signature the ACL is stable and this switch should come out.
  if (!command_line->HasSwitch("use-mock-keychain")) {
    command_line->AppendSwitch("use-mock-keychain");
  }
}

void BRWCefApp::OnScheduleMessagePumpWork(int64_t delay_ms) {
  BRWMessagePump::Get().OnScheduleMessagePumpWork(delay_ms);
}
