#import "BRWEngine.h"

#include <crt_externs.h>  // for _NSGetArgc/_NSGetArgv

#include <map>
#include <string>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_cookie.h"
#include "include/cef_request_context.h"
#include "include/wrapper/cef_library_loader.h"

#import "BRWCefApp.h"
#import "BRWClientHandler.h"
#import "BRWEngineInternal.h"
#import "BRWExtensionsInternal.h"
#include "BRWMessagePump.h"
#import "BRWStringUtil.h"

namespace {

// The CEF framework dylib is copied into Contents/Frameworks but never
// linked directly (a macOS CEF requirement, sandboxed or not); it must be
// dlopen'd at runtime via CefScopedLibraryLoader before any other CEF call.
// Kept alive for the process lifetime -- its destructor unloads the library.
CefScopedLibraryLoader &LibraryLoader() {
  static CefScopedLibraryLoader loader;
  return loader;
}

// One CefRequestContext per profile id, reused across every BRWBrowser
// created for that profile so they share cookies/storage; a different
// profile id gets a distinct context (and thus full isolation). Keyed by
// the profile's stable UUID, not its mutable display name (browser-ojw) --
// see BRWGetOrCreateProfileContext's own doc comment. All contexts'
// cache_path values are children of the single root_cache_path passed to
// +[BRWEngine initializeWithProfilesRootPath:], which CEF requires.
std::map<std::string, CefRefPtr<CefRequestContext>> &ProfileContexts() {
  static std::map<std::string, CefRefPtr<CefRequestContext>> contexts;
  return contexts;
}

std::string &ProfilesRootPath() {
  static std::string root;
  return root;
}

// Non-nil while +requestShutdownWithCompletion: is waiting for every open
// browser's OnBeforeClose. Checked (via +[BRWEngine checkShutdownCompletion])
// after every real CefDoMessageLoopWork() tick in BRWMessagePump::DoWork(),
// the only place CEF's external-pump ticks run -- and fired, exactly once, as soon as
// BRWClientHandler::LiveCount() reaches 0.
using ShutdownCompletionBlock = void (^)(void);
ShutdownCompletionBlock __strong &PendingShutdownCompletion() {
  static ShutdownCompletionBlock completion = nil;
  return completion;
}

// A Chrome-style browser Chromium made on its own (see
// BRWUnmanagedBrowserClient) is closed at once and normally gone in well
// under a second. One that never reports closed must not hold quit up for
// ever, so quitting waits this long for such browsers only, then exits
// without CefShutdown, which CEF does not allow while a browser is alive.
// The app's own browsers are always waited for.
constexpr CFAbsoluteTime kUnmanagedShutdownWaitSeconds = 5.0;
CFAbsoluteTime g_shutdown_requested_at = 0;
bool g_skip_cef_shutdown = false;

// The longest the skip path waits for the cookie stores to flush.
constexpr int64_t kCookieFlushWaitMilliseconds = 2000;

class FlushCallback : public CefCompletionCallback {
 public:
  explicit FlushCallback(void (^done)(void)) : done_([done copy]) {}
  void OnComplete() override { done_(); }

 private:
  void (^done_)(void);
  IMPLEMENT_REFCOUNTING(FlushCallback);
};

// CefShutdown is what writes Chromium's state at quit, so the path that skips
// it first flushes what CEF lets the app flush: every profile's cookie store
// and the global one. `then` runs once, on the main thread, when all have
// reported or after kCookieFlushWaitMilliseconds.
void FlushCookieStoresThen(void (^then)(void)) {
  __block bool finished = false;
  __block int pending = 0;
  void (^finish)(void) = ^{
    if (!finished) {
      finished = true;
      then();
    }
  };
  void (^one_done)(void) = ^{
    if (--pending == 0) {
      finish();
    }
  };
  std::vector<CefRefPtr<CefCookieManager>> managers;
  for (const auto &entry : ProfileContexts()) {
    if (CefRefPtr<CefCookieManager> manager = entry.second->GetCookieManager(nullptr)) {
      managers.push_back(manager);
    }
  }
  if (CefRefPtr<CefCookieManager> global = CefCookieManager::GetGlobalManager(nullptr)) {
    managers.push_back(global);
  }
  pending = static_cast<int>(managers.size()) + 1;
  for (const auto &manager : managers) {
    // The callback runs on the UI thread, which is the main thread here.
    if (!manager->FlushStore(new FlushCallback(one_done))) {
      one_done();
    }
  }
  one_done();
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kCookieFlushWaitMilliseconds * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), finish);
}

void CheckShutdownCompletion() {
  if (!PendingShutdownCompletion() || BRWClientHandler::LiveCount() > 0) {
    return;
  }
  if (BRWUnmanagedBrowserLiveCount() > 0) {
    if (CFAbsoluteTimeGetCurrent() - g_shutdown_requested_at < kUnmanagedShutdownWaitSeconds) {
      return;
    }
    NSLog(@"Browser: quitting without engine shutdown; a window Chromium opened on its own never closed");
    g_skip_cef_shutdown = true;
  }
  // CefShutdown inside a CefDoMessageLoopWork() tick trips a CEF CHECK. The
  // pump checks again the moment that tick returns.
  if (BRWMessagePump::Get().IsPerformingWork()) {
    return;
  }
  ShutdownCompletionBlock completion = PendingShutdownCompletion();
  PendingShutdownCompletion() = nil;
  if (g_skip_cef_shutdown) {
    FlushCookieStoresThen(completion);
  } else {
    completion();
  }
}

// Set via +setWindowCloseHandler:. See that method's doc comment.
using WindowCloseHandlerBlock = void (^)(void);
WindowCloseHandlerBlock __strong &WindowCloseHandler() {
  static WindowCloseHandlerBlock handler = nil;
  return handler;
}

}  // namespace

// Declared in BRWEngineInternal.h -- BRWBrowser.mm is the other caller.
CefRefPtr<CefRequestContext> BRWGetOrCreateProfileContext(const std::string &profile_id) {
  auto &contexts = ProfileContexts();
  auto it = contexts.find(profile_id);
  if (it != contexts.end()) {
    return it->second;
  }

  CefRequestContextSettings settings;
  const std::string cache_path = ProfilesRootPath() + "/" + profile_id;
  CefString(&settings.cache_path) = cache_path;

  CefRefPtr<CefRequestContext> context =
      CefRequestContext::CreateContext(settings, BRWCreateExtensionContextHandler(profile_id));
  // At once, not only when the context reports initialized: an extension's
  // worker can start before that, and its first bridge request must not go
  // out to DNS.
  BRWRegisterExtensionBridgeSchemeHandler(context, profile_id);
  contexts[profile_id] = context;
  return context;
}

// Declared in BRWEngineInternal.h.
bool BRWProfileIdForRequestContext(CefRefPtr<CefRequestContext> context, std::string *profile_id) {
  if (!context) {
    return false;
  }
  for (const auto &entry : ProfileContexts()) {
    if (entry.second->IsSame(context) || entry.second->IsSharingWith(context)) {
      *profile_id = entry.first;
      return true;
    }
  }
  return false;
}

// Declared in BRWEngineInternal.h -- BRWBrowser.mm is the other caller.
CefRefPtr<CefRequestContext> BRWCreateEphemeralRequestContext() {
  // Default-constructed CefRequestContextSettings leaves cache_path empty --
  // that's what puts this context in CEF's "incognito mode" (see this
  // function's own doc comment for the exact header citation). Deliberately
  // NOT inserted into ProfileContexts(): every other context in that map is
  // looked up again later by profile name for reuse across browsers of the
  // same profile, but a private window's context is used exactly once, by
  // exactly the one CefBrowser it backs.
  CefRequestContextSettings settings;
  // A handler with no profile id: no extension runs here, and a request to
  // the extension bridge's reserved host is refused, never sent out.
  CefRefPtr<CefRequestContext> context =
      CefRequestContext::CreateContext(settings, BRWCreateExtensionContextHandler(std::string()));
  BRWRegisterExtensionBridgeSchemeHandler(context, std::string());
  return context;
}

@implementation BRWEngine

+ (BOOL)initializeWithProfilesRootPath:(NSString *)profilesRootPath {
  if (!LibraryLoader().LoadInMain()) {
    NSLog(@"BRWEngine: failed to load the CEF framework library");
    return NO;
  }

  ProfilesRootPath() = ToStdString(profilesRootPath);

  // Real argc/argv (not empty) so CEF actually sees command-line switches
  // such as --enable-logging=stderr, --disable-gpu, etc.
  CefMainArgs main_args(*_NSGetArgc(), *_NSGetArgv());

  CefSettings settings;
  settings.no_sandbox = true;
  settings.multi_threaded_message_loop = false;
  settings.external_message_pump = true;
  settings.windowless_rendering_enabled = false;
  CefString(&settings.root_cache_path) = ProfilesRootPath();

  CefRefPtr<BRWCefApp> app(new BRWCefApp());
  return CefInitialize(main_args, settings, app.get(), nullptr) ? YES : NO;
}

+ (void)checkShutdownCompletion {
  CheckShutdownCompletion();
}

+ (void)shutdown {
  ProfileContexts().clear();
  CefShutdown();
}

+ (void)setWindowCloseHandler:(void (^)(void))handler {
  WindowCloseHandler() = [handler copy];
}

+ (void)requestShutdownWithCompletion:(void (^)(void))completion {
  if (PendingShutdownCompletion()) {
    return;  // Already shutting down (e.g. a second Cmd+Q while quitting).
  }
  g_shutdown_requested_at = CFAbsoluteTimeGetCurrent();
  PendingShutdownCompletion() = [^{
    if (!g_skip_cef_shutdown) {
      [BRWEngine shutdown];
    }
    if (completion) {
      completion();
    }
  } copy];
  // Closes every Swift-owned window through its normal close path first --
  // this is what actually tears down the Tab/BrowserWindowController objects
  // (and, through Tab.close(), most CefBrowsers) before CefShutdown runs.
  // CloseAll() below is then just the safety net for anything that path
  // couldn't reach yet (see its own doc comment).
  if (WindowCloseHandler()) {
    WindowCloseHandler()();
  }
  BRWClientHandler::CloseAll();
  BRWCloseUnmanagedBrowsers();
  // CloseAll() may not have needed to touch CEF at all (no open browsers),
  // in which case the message pump's next tick could be arbitrarily far
  // off (or never come, if the caller relies on this to signal quitting) --
  // so check without waiting on that pump, but on a fresh run-loop turn:
  // this method can itself be running inside a CEF tick (Chromium answers
  // SIGTERM with [NSApp terminate:] from there), and with no browser left
  // a synchronous check would run CefShutdown inside it.
  dispatch_async(dispatch_get_main_queue(), ^{
    CheckShutdownCompletion();
  });
  // The pump may be idle when that wait runs out.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kUnmanagedShutdownWaitSeconds + 0.1) * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    CheckShutdownCompletion();
  });
}

@end
