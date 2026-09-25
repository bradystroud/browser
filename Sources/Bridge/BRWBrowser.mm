#import "BRWBrowser.h"

#include <string>

#include "include/cef_browser.h"
#include "include/cef_image.h"
#include "include/cef_request_context.h"
#include "include/cef_string_visitor.h"
#include "include/cef_task_manager.h"
#include "include/cef_values.h"

#import "BRWClientHandler.h"
#import "BRWEngineInternal.h"
#import "BRWPageMessageRouter.h"
#import "BRWStringUtil.h"

namespace {
// CefStringVisitor is source=client (we implement it, not CEF) -- wraps the
// Swift-facing completion block for -getPageSourceWithCompletion:, same
// pattern as PdfPrintCallback below for -printToPDFWithPath:completion:.
// Always hops to the main thread before calling the block: CEF's own docs
// don't state which thread Visit() runs on, and every other completion in
// this bridge is documented as main-thread-only.
class StringVisitorBlock : public CefStringVisitor {
 public:
  explicit StringVisitorBlock(void (^completion)(NSString *_Nullable source))
      : completion_([completion copy]) {}

  void Visit(const CefString& string) override {
    if (!completion_) {
      return;
    }
    NSString* result = [NSString stringWithUTF8String:string.ToString().c_str()];
    void (^completion)(NSString *) = completion_;
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(result);
    });
  }

 private:
  void (^completion_)(NSString *_Nullable source);
  IMPLEMENT_REFCOUNTING(StringVisitorBlock);
};

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

// CefDownloadImageCallback is source=client -- wraps the Swift-facing
// completion block for -downloadImageAtURL:completion: (browser-5kq.13).
//
// CEF documents this as running on the browser process UI thread, which is
// this app's main thread (see BRWMessagePump), so unlike StringVisitorBlock
// above no dispatch hop is needed to honour the "completion runs on the main
// thread" contract -- but the CefImage must be converted to NSData *here*,
// while the callback still holds the only reference to it.
class DownloadImageCallback : public CefDownloadImageCallback {
 public:
  explicit DownloadImageCallback(void (^completion)(NSData *_Nullable pngData, NSInteger httpStatusCode))
      : completion_([completion copy]) {}

  void OnDownloadImageFinished(const CefString& image_url,
                               int http_status_code,
                               CefRefPtr<CefImage> image) override {
    if (!completion_) {
      return;
    }
    NSData* png = nil;
    if (image && !image->IsEmpty()) {
      // DownloadImage can return the same image at several scale factors;
      // GetAsPNG returns whichever representation "most closely matches"
      // the requested one, so asking for an implausibly high scale factor
      // reliably yields the largest representation actually present rather
      // than a downscaled copy.
      int pixel_width = 0;
      int pixel_height = 0;
      CefRefPtr<CefBinaryValue> data =
          image->GetAsPNG(4.0f, /*with_transparency=*/true, pixel_width, pixel_height);
      if (data && data->GetSize() > 0) {
        NSMutableData* buffer = [NSMutableData dataWithLength:data->GetSize()];
        const size_t copied = data->GetData([buffer mutableBytes], data->GetSize(), 0);
        if (copied == data->GetSize()) {
          png = buffer;
        }
      }
    }
    completion_(png, (NSInteger)http_status_code);
  }

 private:
  void (^completion_)(NSData *_Nullable pngData, NSInteger httpStatusCode);
  IMPLEMENT_REFCOUNTING(DownloadImageCallback);
};
}  // namespace

@implementation BRWBrowser {
  CefRefPtr<BRWClientHandler> _handler;
}

- (instancetype)initWithProfileName:(NSString *)profileName
                            profileId:(NSString *)profileId
                             hostView:(NSView *)hostView
                           initialURL:(NSString *)initialURL {
  self = [super init];
  if (self) {
    // profileName here is only for BRWClientHandler's own (separate,
    // name-keyed) content-blocking snapshot lookup -- see BRWBrowser.h's
    // doc comment on this initializer for why the cache-path lookup just
    // below deliberately uses profileId instead.
    _handler = new BRWClientHandler(hostView, ToStdString(profileName));

    CefWindowInfo window_info;
    CefRect bounds(0, 0, (int)hostView.bounds.size.width, (int)hostView.bounds.size.height);
    window_info.SetAsChild((__bridge void *)hostView, bounds);
    window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;

    CefBrowserSettings browser_settings;
    CefRefPtr<CefRequestContext> request_context =
        BRWGetOrCreateProfileContext(ToStdString(profileId));

    CefBrowserHost::CreateBrowser(window_info, _handler, ToStdString(initialURL),
                                   browser_settings, nullptr, request_context);
  }
  return self;
}

- (instancetype)initPrivateWithHostView:(NSView *)hostView
                              initialURL:(NSString *)initialURL {
  self = [super init];
  if (self) {
    // "private" is a fixed, non-user-visible profile_name -- it has no
    // ProfilesRootPath() directory and is never looked up via
    // BRWGetOrCreateProfileContext, but BRWClientHandler still needs some
    // string to key its own BlockingSettings snapshot lookup (see
    // ContentBlockerCoordinator.swift, which publishes a matching "private"
    // entry so private windows still get content-blocking applied instead of
    // silently no-oping for lack of a snapshot entry).
    _handler = new BRWClientHandler(hostView, "private");

    CefWindowInfo window_info;
    CefRect bounds(0, 0, (int)hostView.bounds.size.width, (int)hostView.bounds.size.height);
    window_info.SetAsChild((__bridge void *)hostView, bounds);
    window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;

    CefBrowserSettings browser_settings;
    CefRefPtr<CefRequestContext> request_context = BRWCreateEphemeralRequestContext();

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

- (void)setResponsiveDesignModeWithWidth:(int)width
                                    height:(int)height
                         deviceScaleFactor:(double)deviceScaleFactor
                                    mobile:(BOOL)mobile {
  if (!_handler || !_handler->GetBrowser()) {
    return;
  }
  // message_id=0 means "assign the next number automatically" -- nothing in
  // this bridge needs to correlate this call with its (fire-and-forget, from
  // this method's own caller's perspective) DevTools protocol response.
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetInt("width", width);
  params->SetInt("height", height);
  params->SetDouble("deviceScaleFactor", deviceScaleFactor);
  params->SetBool("mobile", mobile);
  _handler->GetBrowser()->GetHost()->ExecuteDevToolsMethod(0, "Emulation.setDeviceMetricsOverride", params);
}

- (void)clearResponsiveDesignMode {
  if (!_handler || !_handler->GetBrowser()) {
    return;
  }
  _handler->GetBrowser()->GetHost()->ExecuteDevToolsMethod(0, "Emulation.clearDeviceMetricsOverride", nullptr);
}

- (double)cpuUsagePercent {
  if (!_handler || !_handler->GetBrowser()) {
    return 0.0;
  }
  CefRefPtr<CefTaskManager> task_manager = CefTaskManager::GetTaskManager();
  if (!task_manager) {
    // nullptr means this was called from the wrong thread -- see this
    // method's own doc comment.
    return 0.0;
  }
  int64_t task_id = task_manager->GetTaskIdForBrowserId(_handler->GetBrowser()->GetIdentifier());
  if (task_id == -1) {
    return 0.0;
  }
  CefTaskInfo info;
  if (!task_manager->GetTaskInfo(task_id, info)) {
    return 0.0;
  }
  return info.cpu_usage;
}

- (void)setAudioMuted:(BOOL)muted {
  if (_handler && _handler->GetBrowser()) {
    _handler->GetBrowser()->GetHost()->SetAudioMuted(muted);
  }
}

- (void)setZoomLevel:(double)zoomLevel {
  if (_handler && _handler->GetBrowser()) {
    _handler->GetBrowser()->GetHost()->SetZoomLevel(zoomLevel);
  }
}

- (double)zoomLevel {
  if (!_handler || !_handler->GetBrowser()) {
    return 0.0;
  }
  return _handler->GetBrowser()->GetHost()->GetZoomLevel();
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

- (void)downloadImageAtURL:(NSString *)imageURL
                 completion:(void (^)(NSData *_Nullable pngData, NSInteger httpStatusCode))completion {
  if (!_handler || !_handler->GetBrowser()) {
    if (completion) {
      completion(nil, 0);
    }
    return;
  }
  CefRefPtr<DownloadImageCallback> callback = new DownloadImageCallback(completion);
  _handler->GetBrowser()->GetHost()->DownloadImage(ToStdString(imageURL),
                                                    /*is_favicon=*/false,
                                                    /*max_image_size=*/0,
                                                    /*bypass_cache=*/false,
                                                    callback);
}

- (void)startDownloadForURL:(NSString *)url {
  if (_handler && _handler->GetBrowser()) {
    _handler->GetBrowser()->GetHost()->StartDownload(ToStdString(url));
  }
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

- (void)executeJavaScript:(NSString *)code {
  if (_handler && _handler->GetBrowser() && _handler->GetBrowser()->GetMainFrame()) {
    _handler->GetBrowser()->GetMainFrame()->ExecuteJavaScript(ToStdString(code), "", 0);
  }
}

- (void)getPageSourceWithCompletion:(void (^)(NSString *_Nullable source))completion {
  if (!_handler || !_handler->GetBrowser() || !_handler->GetBrowser()->GetMainFrame()) {
    if (completion) {
      completion(nil);
    }
    return;
  }
  CefRefPtr<StringVisitorBlock> visitor = new StringVisitorBlock(completion);
  _handler->GetBrowser()->GetMainFrame()->GetSource(visitor);
}

- (void)respondToPageMessageWithId:(int64_t)requestId success:(BOOL)success response:(NSString *)response {
  // Global (process-wide) router, not this browser's own _handler -- the
  // requestId came from BRWPageMessageRouter and is unique across every
  // tab, not scoped to whichever BRWBrowser happens to call this.
  BRWPageMessageRouter::Get().Respond(requestId, success, ToStdString(response));
}

+ (void)setVisualLookUpAvailable:(BOOL)available {
  BRWClientHandler::SetVisualLookUpAvailable(available);
}

+ (void)setDownloadDirectory:(NSString *)directory {
  BRWClientHandler::SetDownloadDirectory(ToStdString(directory));
}

@end
