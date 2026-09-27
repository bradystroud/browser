#import "BRWBrowser.h"

#include <string>

#include "include/cef_browser.h"
#include "include/cef_image.h"
#include "include/cef_request_context.h"
#include "include/cef_ssl_status.h"
#include "include/cef_string_visitor.h"
#include "include/cef_task_manager.h"
#include "include/cef_values.h"
#include "include/cef_x509_certificate.h"

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

  // A browser closed while the read is in flight releases the visitor
  // without visiting it. The completion still runs, with nil, so a caller
  // waiting on it (the audio poll, tab sleep) is never left waiting forever.
  ~StringVisitorBlock() override {
    if (visited_ || !completion_) {
      return;
    }
    void (^completion)(NSString *) = completion_;
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(nil);
    });
  }

  void Visit(const CefString& string) override {
    if (!completion_ || visited_) {
      return;
    }
    visited_ = true;
    NSString* result = [NSString stringWithUTF8String:string.ToString().c_str()];
    void (^completion)(NSString *) = completion_;
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(result);
    });
  }

 private:
  void (^completion_)(NSString *_Nullable source);
  bool visited_ = false;
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

@implementation BRWSecurityStatus

@synthesize isSecureConnection = _isSecureConnection;
@synthesize hasCertificateError = _hasCertificateError;
@synthesize hasInsecureContent = _hasInsecureContent;
@synthesize certificateChain = _certificateChain;

- (instancetype)initWithSecureConnection:(BOOL)isSecureConnection
                        certificateError:(BOOL)hasCertificateError
                         insecureContent:(BOOL)hasInsecureContent
                        certificateChain:(NSArray<NSData *> *)certificateChain {
  if ((self = [super init])) {
    _isSecureConnection = isSecureConnection;
    _hasCertificateError = hasCertificateError;
    _hasInsecureContent = hasInsecureContent;
    _certificateChain = [certificateChain copy];
  }
  return self;
}

@end

namespace {
NSData *ToNSData(CefRefPtr<CefBinaryValue> value) {
  if (!value || value->GetSize() == 0) {
    return nil;
  }
  NSMutableData *data = [NSMutableData dataWithLength:value->GetSize()];
  value->GetData(data.mutableBytes, data.length, 0);
  return data;
}

// Chromium's net::IsCertStatusError: bits 0-15 are errors, except the two
// revocation-check bits it calls minor (net::IsCertStatusMinorError), which
// never turn its own lock red either.
bool IsCertStatusError(cef_cert_status_t status) {
  const uint32_t all_errors = 0xFFFF;
  const uint32_t minor = CERT_STATUS_NO_REVOCATION_MECHANISM | CERT_STATUS_UNABLE_TO_CHECK_REVOCATION;
  return (static_cast<uint32_t>(status) & all_errors & ~minor) != 0;
}
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
  [self showDevToolsInView:nil panel:BRWDevToolsPanelDefault];
}

- (void)showDevToolsInView:(NSView *)container panel:(BRWDevToolsPanel)panel {
  BRWDevToolsHandler::Request request;
  request.container = container;
  request.panel = panel;
  BRWDevToolsHandler::Show(_handler.get(), request);
}

- (void)inspectElementAtPoint:(NSPoint)point inView:(NSView *)container {
  if (!_handler) {
    return;
  }
  // CEF wants the inspected view's own coordinates with a top-left origin.
  NSView *hostView = _handler->GetHostView();
  const CGFloat y = (hostView && !hostView.isFlipped) ? hostView.bounds.size.height - point.y : point.y;
  BRWDevToolsHandler::Request request;
  request.container = container;
  request.has_point = true;
  request.x = (int)lround(point.x);
  request.y = (int)lround(y);
  BRWDevToolsHandler::Show(_handler.get(), request);
}

- (void)startElementPickerInView:(NSView *)container {
  BRWDevToolsHandler::Request request;
  request.container = container;
  request.start_picker = true;
  BRWDevToolsHandler::Show(_handler.get(), request);
}

- (void)closeDevTools {
  BRWDevToolsHandler::Close(_handler.get());
}

- (BOOL)isDevToolsOpen {
  return BRWDevToolsHandler::IsOpen(_handler.get());
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

- (BRWSecurityStatus *)securityStatus {
  if (!_handler || !_handler->GetBrowser()) {
    return nil;
  }
  CefRefPtr<CefNavigationEntry> entry = _handler->GetBrowser()->GetHost()->GetVisibleNavigationEntry();
  if (!entry || !entry->IsValid()) {
    return nil;
  }
  CefRefPtr<CefSSLStatus> ssl = entry->GetSSLStatus();
  if (!ssl) {
    return nil;
  }
  NSMutableArray<NSData *> *chain = [NSMutableArray array];
  if (CefRefPtr<CefX509Certificate> certificate = ssl->GetX509Certificate()) {
    if (NSData *leaf = ToNSData(certificate->GetDEREncoded())) {
      [chain addObject:leaf];
      CefX509Certificate::IssuerChainBinaryList issuers;
      certificate->GetDEREncodedIssuerChain(issuers);
      for (const auto &issuer : issuers) {
        if (NSData *data = ToNSData(issuer)) {
          [chain addObject:data];
        }
      }
    }
  }
  const int content = ssl->GetContentStatus();
  return [[BRWSecurityStatus alloc]
      initWithSecureConnection:ssl->IsSecureConnection()
              certificateError:IsCertStatusError(ssl->GetCertStatus())
               insecureContent:(content & (SSL_CONTENT_DISPLAYED_INSECURE_CONTENT | SSL_CONTENT_RAN_INSECURE_CONTENT)) != 0
              certificateChain:chain];
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
