#import "BRWBrowser.h"

#include <string>

#include "include/cef_browser.h"
#include "include/cef_request_context.h"

#import "BRWClientHandler.h"
#import "BRWEngineInternal.h"

namespace {
std::string ToStdString(NSString *s) {
  return s ? std::string([s UTF8String]) : std::string();
}
}  // namespace

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
        BRWGetOrCreateProfileContext(ToStdString(profileName));

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
  if (_handler) {
    _handler->RequestClose();
  }
}

- (void)showDevTools {
  if (_handler && _handler->GetBrowser()) {
    // Default-constructed CefWindowInfo/CefBrowserSettings and a nullptr
    // client all mean "let CEF manage this itself" -- ShowDevTools then
    // pops its own separate native DevTools window, which is CEF's
    // documented behavior for this call and the simplest thing that works
    // for a v1 (a version docked into a view we own would need its own
    // CefClient and SetAsChild plumbing, tracked as a later enhancement if
    // ever needed). An empty CefPoint() for inspect_element_at means "no
    // specific element" -- see BRWBrowser.h's -showDevTools for the
    // right-click "Inspect Element" path, which passes a real point instead
    // (that wiring lives in BRWClientHandler's context-menu handler once
    // added; this method alone only covers the menu/shortcut entry point).
    CefWindowInfo window_info;
    CefBrowserSettings settings;
    _handler->GetBrowser()->GetHost()->ShowDevTools(window_info, nullptr, settings, CefPoint());
  }
}

- (void)closeDevTools {
  if (_handler && _handler->GetBrowser()) {
    _handler->GetBrowser()->GetHost()->CloseDevTools();
  }
}

@end
