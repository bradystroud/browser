#import "BRWEngine.h"

#include <crt_externs.h>  // for _NSGetArgc/_NSGetArgv

#include <map>
#include <string>

#include "include/cef_app.h"
#include "include/cef_request_context.h"
#include "include/wrapper/cef_library_loader.h"

#import "BRWCefApp.h"
#import "BRWClientHandler.h"
#import "BRWEngineInternal.h"

namespace {

// The CEF framework dylib is copied into Contents/Frameworks but never
// linked directly (a macOS CEF requirement, sandboxed or not); it must be
// dlopen'd at runtime via CefScopedLibraryLoader before any other CEF call.
// Kept alive for the process lifetime -- its destructor unloads the library.
CefScopedLibraryLoader &LibraryLoader() {
  static CefScopedLibraryLoader loader;
  return loader;
}

std::string ToStdString(NSString *s) {
  return s ? std::string([s UTF8String]) : std::string();
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
// after every real CefDoMessageLoopWork() tick -- BRWMessagePump::DoWork(),
// not +[BRWEngine doMessageLoopWork] (nothing calls that method; CEF's actual
// external-pump ticks all run through BRWMessagePump, which calls
// CefDoMessageLoopWork() directly) -- and fired, exactly once, as soon as
// BRWClientHandler::LiveCount() reaches 0.
using ShutdownCompletionBlock = void (^)(void);
ShutdownCompletionBlock __strong &PendingShutdownCompletion() {
  static ShutdownCompletionBlock completion = nil;
  return completion;
}

void CheckShutdownCompletion() {
  if (!PendingShutdownCompletion() || BRWClientHandler::LiveCount() > 0) {
    return;
  }
  ShutdownCompletionBlock completion = PendingShutdownCompletion();
  PendingShutdownCompletion() = nil;
  completion();
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
      CefRequestContext::CreateContext(settings, nullptr);
  contexts[profile_id] = context;
  return context;
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
  return CefRequestContext::CreateContext(settings, nullptr);
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
  settings.no_sandbox = true;  // See docs/ai-tasks/m0-spike-notes.md for rationale.
  settings.multi_threaded_message_loop = false;
  settings.external_message_pump = true;
  settings.windowless_rendering_enabled = false;
  CefString(&settings.root_cache_path) = ProfilesRootPath();

  CefRefPtr<BRWCefApp> app(new BRWCefApp());
  return CefInitialize(main_args, settings, app.get(), nullptr) ? YES : NO;
}

+ (void)doMessageLoopWork {
  CefDoMessageLoopWork();
  CheckShutdownCompletion();
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
  PendingShutdownCompletion() = [^{
    [BRWEngine shutdown];
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
  // CloseAll() may not have needed to touch CEF at all (no open browsers),
  // in which case doMessageLoopWork's next tick could be arbitrarily far
  // off (or never come, if the caller relies on this to signal quitting) --
  // check right away rather than waiting on that pump.
  CheckShutdownCompletion();
}

@end
