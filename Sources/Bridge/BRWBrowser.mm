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

// CefPdfPrintCallback is source=client (we implement it, not CEF) -- wraps
// the Swift-facing completion block so -printToPDFWithPath:completion: never
// exposes a CEF type across the bridge boundary.
class PdfPrintCallback : public CefPdfPrintCallback {
 public:
  explicit PdfPrintCallback(void (^completion)(BOOL success, NSString *path))
      : completion_([completion copy]) {}

  void OnPdfPrintFinished(const CefString& path, bool ok) override {
    if (completion_) {
      completion_(ok, [NSString stringWithUTF8String:path.ToString().c_str()]);
    }
  }

 private:
  void (^completion_)(BOOL success, NSString *path);
  IMPLEMENT_REFCOUNTING(PdfPrintCallback);
};
}  // namespace

@implementation BRWBrowser {
  CefRefPtr<BRWClientHandler> _handler;
}

- (instancetype)initWithProfileName:(NSString *)profileName
                             hostView:(NSView *)hostView
                           initialURL:(NSString *)initialURL {
  self = [super init];
  if (self) {
    _handler = new BRWClientHandler(hostView, ToStdString(profileName));

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

- (void)print {
  if (_handler && _handler->GetBrowser()) {
    _handler->GetBrowser()->GetHost()->Print();
  }
}

- (void)printToPDFWithPath:(NSString *)path completion:(void (^)(BOOL success, NSString *path))completion {
  if (!_handler || !_handler->GetBrowser()) {
    if (completion) {
      completion(NO, path);
    }
    return;
  }
  // Default-constructed CefPdfPrintSettings: PDF_PRINT_MARGIN_DEFAULT (~1cm
  // margins), scale <= 0 treated as 1.0 (100%), paper_width/height <= 0
  // treated as letter (8.5x11in) -- CEF's own documented defaults for every
  // field this leaves untouched. No UI exposes any of these yet.
  CefPdfPrintSettings settings;
  CefRefPtr<PdfPrintCallback> callback = new PdfPrintCallback(completion);
  _handler->GetBrowser()->GetHost()->PrintToPDF(ToStdString(path), settings, callback);
}

- (void)find:(NSString *)searchText forward:(BOOL)forward matchCase:(BOOL)matchCase findNext:(BOOL)findNext {
  if (_handler && _handler->GetBrowser()) {
    _handler->GetBrowser()->GetHost()->Find(ToStdString(searchText), forward, matchCase, findNext);
  }
}

- (void)stopFinding:(BOOL)clearSelection {
  if (_handler && _handler->GetBrowser()) {
    _handler->GetBrowser()->GetHost()->StopFinding(clearSelection);
  }
}

@end
