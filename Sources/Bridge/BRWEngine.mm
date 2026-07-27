#import "BRWEngine.h"

#include <crt_externs.h>  // for _NSGetArgc/_NSGetArgv

#include <map>
#include <string>

#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_request_context.h"
#include "include/wrapper/cef_library_loader.h"

#import "BRWCefApp.h"
#import "BRWClientHandler.h"

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

// One CefRequestContext per profile name, reused across every BRWBrowser
// created for that profile so they share cookies/storage; a different
// profile name gets a distinct context (and thus full isolation). All
// contexts' cache_path values are children of the single root_cache_path
// passed to +[BRWEngine initializeWithProfilesRootPath:], which CEF requires.
std::map<std::string, CefRefPtr<CefRequestContext>> &ProfileContexts() {
  static std::map<std::string, CefRefPtr<CefRequestContext>> contexts;
  return contexts;
}

std::string &ProfilesRootPath() {
  static std::string root;
  return root;
}

CefRefPtr<CefRequestContext> GetOrCreateProfileContext(const std::string &profile_name) {
  auto &contexts = ProfileContexts();
  auto it = contexts.find(profile_name);
  if (it != contexts.end()) {
    return it->second;
  }

  CefRequestContextSettings settings;
  const std::string cache_path = ProfilesRootPath() + "/" + profile_name;
  CefString(&settings.cache_path) = cache_path;

  CefRefPtr<CefRequestContext> context =
      CefRequestContext::CreateContext(settings, nullptr);
  contexts[profile_name] = context;
  return context;
}

}  // namespace

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
}

+ (void)shutdown {
  ProfileContexts().clear();
  CefShutdown();
}

@end

@implementation BRWBrowser {
  CefRefPtr<BRWClientHandler> _handler;
}

- (instancetype)initWithProfileName:(NSString *)profileName
                             hostView:(NSView *)hostView
                           initialURL:(NSString *)initialURL {
  self = [super init];
  if (self) {
    _handler = new BRWClientHandler(hostView);

    CefWindowInfo window_info;
    CefRect bounds(0, 0, (int)hostView.bounds.size.width, (int)hostView.bounds.size.height);
    window_info.SetAsChild((__bridge void *)hostView, bounds);
    window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;

    CefBrowserSettings browser_settings;
    CefRefPtr<CefRequestContext> request_context =
        GetOrCreateProfileContext(ToStdString(profileName));

    CefBrowserHost::CreateBrowser(window_info, _handler, ToStdString(initialURL),
                                   browser_settings, nullptr, request_context);
  }
  return self;
}

- (void)setDelegate:(id<BRWBrowserDelegate>)delegate {
  if (_handler) {
    _handler->SetDelegate(delegate);
  }
}

- (id<BRWBrowserDelegate>)delegate {
  return _handler ? _handler->GetDelegate() : nil;
}

- (void)loadURL:(NSString *)url {
  if (_handler) {
    _handler->LoadURLWhenReady(ToStdString(url));
  }
}

- (void)goBack {
  if (_handler && _handler->GetBrowser()) {
    _handler->GetBrowser()->GoBack();
  }
}

- (void)goForward {
  if (_handler && _handler->GetBrowser()) {
    _handler->GetBrowser()->GoForward();
  }
}

- (void)reload {
  if (_handler && _handler->GetBrowser()) {
    _handler->GetBrowser()->Reload();
  }
}

- (void)close {
  if (_handler && _handler->GetBrowser() && !_handler->IsClosed()) {
    _handler->GetBrowser()->GetHost()->CloseBrowser(true);
  }
}

@end
