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
  if (_handler && _handler->GetBrowser() && !_handler->IsClosed()) {
    _handler->GetBrowser()->GetHost()->CloseBrowser(true);
  }
}

@end
