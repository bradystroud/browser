#import "BRWCefApp.h"

#import <Foundation/Foundation.h>

#import "BRWMessagePump.h"

BRWCefApp::BRWCefApp() = default;

void BRWCefApp::OnBeforeCommandLineProcessing(
    const CefString& process_type,
    CefRefPtr<CefCommandLine> command_line) {
  // Ad-hoc-signed local builds have no stable Team ID, so the OS treats every
  // launch as a different app for Keychain ACL purposes: Chromium's OSCrypt
  // "Chromium Safe Storage" item would prompt a (secure-input, unautomatable)
  // keychain dialog on first cookie access for every profile, every launch.
  // Mock keychain sidesteps that for local dev. A real Developer ID signature
  // gives a stable Team ID instead, so that ACL match holds reliably --
  // scripts/release.sh (and scripts/build.sh, browser-35t) plants
  // BRWDisableMockKeychain in Contents/Info.plist before signing with a real
  // identity, specifically so this switch turns itself off for exactly those
  // builds and stays on for every ad-hoc/local dev build automatically (they
  // never get the key set at all, so objectForInfoDictionaryKey: returns nil
  // and boolValue on nil is NO, preserving today's behavior by default).
  BOOL disableMockKeychain =
      [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"BRWDisableMockKeychain"] boolValue];
  if (!disableMockKeychain && !command_line->HasSwitch("use-mock-keychain")) {
    command_line->AppendSwitch("use-mock-keychain");
  }
}

void BRWCefApp::OnScheduleMessagePumpWork(int64_t delay_ms) {
  BRWMessagePump::Get().OnScheduleMessagePumpWork(delay_ms);
}
