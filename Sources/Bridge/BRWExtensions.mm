#import "BRWExtensions.h"

#import <AppKit/AppKit.h>

#include <algorithm>
#include <cstring>
#include <map>
#include <mutex>
#include <set>
#include <string>
#include <vector>

#include "include/cef_browser.h"
#include "include/cef_parser.h"
#include "include/cef_request.h"
#include "include/cef_resource_handler.h"
#include "include/cef_response.h"
#include "include/cef_scheme.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_helpers.h"

#import "BRWEngineInternal.h"
#import "BRWExtensionsInternal.h"
#import "BRWStringUtil.h"

namespace {

constexpr char kBridgeHost[] = "extension-bridge.browser.invalid";
constexpr char kBridgePathPrefix[] = "/v1/";
constexpr char kRedirectRefusedPath[] = "/redirect-refused";
constexpr size_t kMaxKindLength = 64;
// The shim's messages are small intents (a URL or a short list of them, a
// lifecycle event). Anything this large is not one of them.
constexpr size_t kMaxBodyBytes = 64 * 1024;
// Requests one extension may have waiting on the app at once. The shim sends
// one per user-visible intent, so a burst past this is a loop or abuse, and
// each waiting request holds a reply block on the main thread.
constexpr int kMaxInFlightPerExtension = 16;

std::mutex& InFlightMutex() {
  static std::mutex mutex;
  return mutex;
}

std::map<std::string, int>& InFlightByExtension() {
  static std::map<std::string, int> counts;
  return counts;
}

bool ReserveInFlight(const std::string& extension_id) {
  std::lock_guard<std::mutex> lock(InFlightMutex());
  int& count = InFlightByExtension()[extension_id];
  if (count >= kMaxInFlightPerExtension) {
    return false;
  }
  count++;
  return true;
}

void ReleaseInFlight(const std::string& extension_id) {
  std::lock_guard<std::mutex> lock(InFlightMutex());
  auto it = InFlightByExtension().find(extension_id);
  if (it != InFlightByExtension().end() && --it->second <= 0) {
    InFlightByExtension().erase(it);
  }
}

std::vector<std::string>& LoadExtensionPaths() {
  static std::vector<std::string> paths;
  return paths;
}

// Set once CefInitialize has read the command line; later paths could never
// reach Chromium.
bool& LoadExtensionSwitchConsumed() {
  static bool consumed = false;
  return consumed;
}

__weak id<BRWExtensionRuntimeDelegate> g_delegate = nil;
NSTimeInterval g_request_timeout = 10.0;
bool g_keep_external_extension_switches = false;

// Chromium switches that load, unlock or reconfigure extensions.
bool IsExtensionLoadingSwitch(const std::string& name) {
  return name == "load-extension" || name == "disable-extensions-except" ||
         name == "enable-unsafe-extension-debugging" || name.rfind("extensions-", 0) == 0 ||
         name.rfind("extension-", 0) == 0;
}

// "chrome-extension://<id>" is how Chromium serializes an extension origin.
// An extension id is 32 characters from a to p.
bool ExtensionIdFromInitiator(const std::string& initiator, std::string* extension_id) {
  static const std::string prefix = "chrome-extension://";
  if (initiator.compare(0, prefix.size(), prefix) != 0) {
    return false;
  }
  std::string rest = initiator.substr(prefix.size());
  if (!rest.empty() && rest.back() == '/') {
    rest.pop_back();
  }
  if (rest.size() != 32) {
    return false;
  }
  for (char c : rest) {
    if (c < 'a' || c > 'p') {
      return false;
    }
  }
  *extension_id = rest;
  return true;
}

bool KindFromPath(const std::string& path, std::string* kind) {
  const size_t prefix_length = sizeof(kBridgePathPrefix) - 1;
  if (path.compare(0, prefix_length, kBridgePathPrefix) != 0) {
    return false;
  }
  const std::string rest = path.substr(prefix_length);
  if (rest.empty() || rest.size() > kMaxKindLength) {
    return false;
  }
  for (char c : rest) {
    const bool allowed = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
                         c == '.' || c == '_' || c == '-';
    if (!allowed) {
      return false;
    }
  }
  *kind = rest;
  return true;
}

bool ReadBody(CefRefPtr<CefRequest> request, std::string* body) {
  CefRefPtr<CefPostData> post_data = request->GetPostData();
  if (!post_data) {
    return true;
  }
  CefPostData::ElementVector elements;
  post_data->GetElements(elements);
  for (const auto& element : elements) {
    if (element->GetType() != PDE_TYPE_BYTES) {
      return false;  // A file or empty element: not a JSON body.
    }
    const size_t count = element->GetBytesCount();
    if (body->size() + count > kMaxBodyBytes) {
      return false;
    }
    const size_t offset = body->size();
    body->resize(offset + count);
    element->GetBytes(count, &(*body)[offset]);
  }
  return true;
}

bool IsJSON(const std::string& text) {
  if (text.empty()) {
    return false;
  }
  NSData* data = [NSData dataWithBytes:text.data() length:text.size()];
  return [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil] != nil;
}

std::string ErrorJSON(const char* message) {
  return std::string("{\"error\":\"") + message + "\"}";
}

// Answers one request to the bridge host. Either the answer is known when it
// is created (every refusal), or the request goes to the delegate on the main
// thread and the answer arrives later, from any thread, through Complete().
class BridgeResourceHandler : public CefResourceHandler {
 public:
  // A refusal an extension may read. `allow_origin` is the extension origin
  // to grant CORS read access to.
  BridgeResourceHandler(int status, std::string body, std::string allow_origin)
      : immediate_(true), allow_origin_(std::move(allow_origin)), status_(status), body_(std::move(body)) {}

  // A refusal for anything that is not an extension of this profile. It
  // fails as a host that does not resolve fails, so a web page cannot tell
  // this host is special and learns nothing about the browser.
  static CefRefPtr<BridgeResourceHandler> Unresolvable() {
    CefRefPtr<BridgeResourceHandler> handler = new BridgeResourceHandler(0, std::string(), std::string());
    handler->unresolvable_ = true;
    return handler;
  }

  // A request for the delegate.
  BridgeResourceHandler(std::string profile_id, std::string extension_id, std::string kind)
      : immediate_(false),
        allow_origin_("chrome-extension://" + extension_id),
        profile_id_(std::move(profile_id)),
        extension_id_(std::move(extension_id)),
        kind_(std::move(kind)) {}

  bool Open(CefRefPtr<CefRequest> request, bool& handle_request, CefRefPtr<CefCallback> callback) override {
    if (immediate_) {
      handle_request = true;
      return true;
    }
    const std::string method = request->GetMethod().ToString();
    if (method == "OPTIONS") {
      // A CORS preflight. The prepared manifest's host permission normally
      // makes the extension skip it; answering it keeps a missing permission
      // from turning into an opaque network error.
      SetImmediate(204, std::string());
      preflight_ = true;
      handle_request = true;
      return true;
    }
    if (method != "POST") {
      SetImmediate(405, ErrorJSON("method not allowed"));
      handle_request = true;
      return true;
    }
    std::string body;
    if (!ReadBody(request, &body) || !IsJSON(body)) {
      SetImmediate(400, ErrorJSON("body must be JSON of at most 64 KB"));
      handle_request = true;
      return true;
    }

    {
      std::lock_guard<std::mutex> lock(mutex_);
      callback_ = callback;
    }
    handle_request = false;

    CefRefPtr<BridgeResourceHandler> self(this);
    NSString* kind = [NSString stringWithUTF8String:kind_.c_str()];
    NSString* extension_id = [NSString stringWithUTF8String:extension_id_.c_str()];
    NSString* profile_id = [NSString stringWithUTF8String:profile_id_.c_str()];
    NSString* payload = [[NSString alloc] initWithBytes:body.data() length:body.size() encoding:NSUTF8StringEncoding];
    if (!payload) {
      SetImmediate(400, ErrorJSON("body must be UTF-8"));
      handle_request = true;
      return true;
    }
    if (!ReserveInFlight(extension_id_)) {
      SetImmediate(429, ErrorJSON("too many requests"));
      handle_request = true;
      return true;
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      holds_in_flight_ = true;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      id<BRWExtensionRuntimeDelegate> delegate = g_delegate;
      if (!delegate) {
        self->Complete(503, ErrorJSON("no handler"));
        self->Settle();
        return;
      }
      const NSTimeInterval timeout = g_request_timeout;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self->Complete(504, ErrorJSON("timeout"));
        self->Settle();
      });
      [delegate extensionRuntimeDidReceiveRequestWithKind:kind
                                              extensionId:extension_id
                                                profileId:profile_id
                                              payloadJSON:payload
                                                    reply:^(BOOL success, NSString* replyJSON) {
        if (success) {
          self->Complete(200, replyJSON ? ToStdString(replyJSON) : std::string("null"));
        } else {
          self->Complete(400, replyJSON ? ToStdString(replyJSON) : ErrorJSON("rejected"));
        }
        self->Settle();
      }];
    });
    return true;
  }

  void GetResponseHeaders(CefRefPtr<CefResponse> response, int64_t& response_length, CefString& redirectUrl) override {
    std::lock_guard<std::mutex> lock(mutex_);
    if (unresolvable_) {
      response->SetError(ERR_NAME_NOT_RESOLVED);
      response_length = 0;
      return;
    }
    response->SetStatus(status_);
    response->SetStatusText(StatusText(status_));
    CefResponse::HeaderMap headers;
    headers.insert(std::make_pair("Cache-Control", "no-store"));
    if (!allow_origin_.empty()) {
      headers.insert(std::make_pair("Access-Control-Allow-Origin", allow_origin_));
      if (preflight_) {
        headers.insert(std::make_pair("Access-Control-Allow-Methods", "POST"));
        headers.insert(std::make_pair("Access-Control-Allow-Headers", "Content-Type"));
      }
    }
    response->SetHeaderMap(headers);
    if (!body_.empty()) {
      response->SetMimeType("application/json");
      response->SetCharset("utf-8");
    }
    response_length = static_cast<int64_t>(body_.size());
  }

  bool Read(void* data_out, int bytes_to_read, int& bytes_read, CefRefPtr<CefResourceReadCallback> callback) override {
    std::lock_guard<std::mutex> lock(mutex_);
    if (offset_ >= body_.size()) {
      bytes_read = 0;
      return false;
    }
    const size_t count = std::min(static_cast<size_t>(bytes_to_read), body_.size() - offset_);
    memcpy(data_out, body_.data() + offset_, count);
    offset_ += count;
    bytes_read = static_cast<int>(count);
    return true;
  }

  // The sender went away. The request still holds its in-flight slot until
  // the delegate answers or the timeout fires (Settle), so a fetch that is
  // sent and aborted at once cannot get past the cap.
  void Cancel() override {
    std::lock_guard<std::mutex> lock(mutex_);
    answered_ = true;
    callback_ = nullptr;
  }

  // The delegate answered or the request timed out: frees the in-flight
  // slot, once.
  void Settle() {
    bool release = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      release = holds_in_flight_;
      holds_in_flight_ = false;
    }
    if (release) {
      ReleaseInFlight(extension_id_);
    }
  }

  // The first answer wins; a later reply, the timeout after a reply, or any
  // answer after Cancel does nothing.
  void Complete(int status, std::string body) {
    CefRefPtr<CefCallback> callback;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (answered_) {
        return;
      }
      answered_ = true;
      status_ = status;
      body_ = std::move(body);
      callback = callback_;
      callback_ = nullptr;
    }
    if (callback) {
      callback->Continue();
    }
  }

 private:
  void SetImmediate(int status, std::string body) {
    std::lock_guard<std::mutex> lock(mutex_);
    answered_ = true;
    status_ = status;
    body_ = std::move(body);
  }

  static const char* StatusText(int status) {
    switch (status) {
      case 200: return "OK";
      case 204: return "No Content";
      case 400: return "Bad Request";
      case 403: return "Forbidden";
      case 404: return "Not Found";
      case 405: return "Method Not Allowed";
      case 429: return "Too Many Requests";
      case 503: return "Service Unavailable";
      case 504: return "Gateway Timeout";
      default: return "";
    }
  }

  const bool immediate_;
  const std::string allow_origin_;
  const std::string profile_id_;
  const std::string extension_id_;
  const std::string kind_;

  std::mutex mutex_;
  bool unresolvable_ = false;
  bool answered_ = false;
  bool holds_in_flight_ = false;
  bool preflight_ = false;
  int status_ = 500;
  std::string body_;
  size_t offset_ = 0;
  CefRefPtr<CefCallback> callback_;

  IMPLEMENT_REFCOUNTING(BridgeResourceHandler);
};

// ---- Profile context initialization ----

using ContextCompletion = void (^)(void);

// UI thread only, like every map here.
std::set<std::string>& InitializedProfileContexts() {
  static std::set<std::string> profiles;
  return profiles;
}

std::map<std::string, std::vector<ContextCompletion>>& PendingContextCompletions() {
  static std::map<std::string, std::vector<ContextCompletion>> pending;
  return pending;
}

bool g_engine_context_initialized = false;

void NoteProfileContextInitialized(const std::string& profile_id) {
  InitializedProfileContexts().insert(profile_id);
  std::vector<ContextCompletion> completions;
  auto it = PendingContextCompletions().find(profile_id);
  if (it != PendingContextCompletions().end()) {
    completions = std::move(it->second);
    PendingContextCompletions().erase(it);
  }
  NSString* profile = [NSString stringWithUTF8String:profile_id.c_str()];
  // Outside CEF's callback: the app's answer is to create the next context.
  dispatch_async(dispatch_get_main_queue(), ^{
    for (ContextCompletion completion : completions) {
      completion();
    }
    id<BRWExtensionRuntimeDelegate> delegate = g_delegate;
    if ([delegate respondsToSelector:@selector(extensionRuntimeProfileContextDidInitialize:)]) {
      [delegate extensionRuntimeProfileContextDidInitialize:profile];
    }
  });
}

class BridgeResourceRequestHandler : public CefResourceRequestHandler {
 public:
  explicit BridgeResourceRequestHandler(CefRefPtr<BridgeResourceHandler> handler) : handler_(handler) {}

  CefRefPtr<CefResourceHandler> GetResourceHandler(CefRefPtr<CefBrowser> browser,
                                                   CefRefPtr<CefFrame> frame,
                                                   CefRefPtr<CefRequest> request) override {
    return handler_;
  }

 private:
  CefRefPtr<BridgeResourceHandler> handler_;
  IMPLEMENT_REFCOUNTING(BridgeResourceRequestHandler);
};

class ExtensionContextHandler : public CefRequestContextHandler {
 public:
  explicit ExtensionContextHandler(std::string profile_id) : profile_id_(std::move(profile_id)) {}

  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(CefRefPtr<CefBrowser> browser,
                                                                 CefRefPtr<CefFrame> frame,
                                                                 CefRefPtr<CefRequest> request,
                                                                 bool is_navigation,
                                                                 bool is_download,
                                                                 const CefString& request_initiator,
                                                                 bool& disable_default_handling) override {
    return BRWExtensionBridgeHandlerForRequest(profile_id_, request, request_initiator, disable_default_handling);
  }

  void OnRequestContextInitialized(CefRefPtr<CefRequestContext> request_context) override {
    CEF_REQUIRE_UI_THREAD();
    // Before the initialized signal goes out, so no extension of this
    // context can run before the bridge covers its service worker.
    BRWRegisterExtensionBridgeSchemeHandler(request_context, profile_id_);
    if (!profile_id_.empty()) {
      NoteProfileContextInitialized(profile_id_);
    }
  }

 private:
  const std::string profile_id_;
  IMPLEMENT_REFCOUNTING(ExtensionContextHandler);
};

// ---- Chrome-style browsers Chromium creates on its own ----

class BlockTask : public CefTask {
 public:
  explicit BlockTask(void (^block)(void)) : block_([block copy]) {}
  void Execute() override { block_(); }

 private:
  void (^block_)(void);
  IMPLEMENT_REFCOUNTING(BlockTask);
};

// How long an unmanaged browser holds back app activation. Chromium asks to
// activate in the task that shows the window, right after OnAfterCreated,
// and the bridge closes it one task later (observed: closed 120-200 ms after
// creation). Three seconds covers a slow machine many times over, and bounds
// the guard if a close never reports back, so app activation can never stay
// blocked.
constexpr CFAbsoluteTime kUnmanagedActivationGuardSeconds = 3.0;

// A hard limit on the guard as a whole: activation is held back for at most
// kActivationGuardBudgetSeconds of guard time in every
// kActivationGuardPeriodSeconds. Only time the guard actually ran is charged
// (an early close gives back the rest), so every stray window gets its guard
// until the budget is really spent, while a stream of windows (a loop in
// Chromium, or code that got past the shim) still cannot keep the app's own
// activation (a routed link, AppActivation) blocked for long.
constexpr CFAbsoluteTime kActivationGuardBudgetSeconds = 5.0;
constexpr CFAbsoluteTime kActivationGuardPeriodSeconds = 60.0;
// How long activation stays held back after the last stray window closed:
// Chromium can still ask from tasks it posted while the window lived.
constexpr CFAbsoluteTime kActivationGuardAfterCloseSeconds = 1.0;
CFAbsoluteTime g_activation_guard_period_start = -kActivationGuardPeriodSeconds;
CFAbsoluteTime g_activation_guard_used = 0;
// Activation is held back while now < g_activation_guard_until.
CFAbsoluteTime g_activation_guard_until = 0;

// Extends the guard to `wanted_until`, as far as the budget allows. UI thread.
void ExtendActivationGuard(CFAbsoluteTime now, CFAbsoluteTime wanted_until) {
  if (now - g_activation_guard_period_start >= kActivationGuardPeriodSeconds) {
    g_activation_guard_period_start = now;
    g_activation_guard_used = 0;
  }
  const CFAbsoluteTime from = std::max(now, g_activation_guard_until);
  const CFAbsoluteTime wanted = wanted_until - from;
  if (wanted <= 0) {
    return;
  }
  const CFAbsoluteTime granted = std::min(wanted, kActivationGuardBudgetSeconds - g_activation_guard_used);
  if (granted <= 0) {
    NSLog(@"Browser: not holding back app activation for a window Chromium opened on its own; the guard's budget is spent");
    return;
  }
  g_activation_guard_used += granted;
  g_activation_guard_until = from + granted;
}

// Ends the guard at `until` when that is sooner, giving the unused time back
// to the budget. UI thread.
void ShortenActivationGuard(CFAbsoluteTime until) {
  if (until < g_activation_guard_until) {
    g_activation_guard_used = std::max<CFAbsoluteTime>(0, g_activation_guard_used - (g_activation_guard_until - until));
    g_activation_guard_until = until;
  }
}

struct UnmanagedEntry {
  CefRefPtr<CefBrowser> browser;
  std::string profile_id;
  bool has_profile = false;
  std::string url;
  bool close_requested = false;
  bool own_window_hidden = false;
  __weak NSWindow* own_window = nil;
  CFAbsoluteTime created_at = 0;
  // Windows made transparent before this browser's own window was known;
  // every one but its own is restored in the close task.
  std::vector<__weak NSWindow*> provisionally_hidden;
};

// Keyed by CefBrowser identifier. UI thread only.
std::map<int, UnmanagedEntry>& UnmanagedEntries() {
  static std::map<int, UnmanagedEntry> entries;
  return entries;
}


NSWindow* WindowOfBrowser(CefRefPtr<CefBrowser> browser) {
  NSView* view = (__bridge NSView*)(void*)browser->GetHost()->GetWindowHandle();
  return view.window;
}

void MakeTransparent(NSWindow* window) {
  window.alphaValue = 0;
  window.ignoresMouseEvents = YES;
}

// Hides the browser's own window once CEF can name it. CEF cannot yet in
// OnAfterCreated for a Chrome-style browser (observed: no window handle), so
// this is tried again at the first navigation and in the close task.
void HideOwnWindow(UnmanagedEntry& entry) {
  if (entry.own_window_hidden) {
    return;
  }
  NSWindow* window = WindowOfBrowser(entry.browser);
  if (window) {
    MakeTransparent(window);
    entry.own_window = window;
    entry.own_window_hidden = true;
  }
}

// Undoes the provisional hiding for every window but the browser's own.
// Called once the browser has closed, when its own window is gone, or after
// the guard lifetime if it never closes. The browser's own window is never
// restored: a window Chromium made on its own stays transparent, ignoring the
// mouse and ordered out, for its whole life.
void RestoreProvisionallyHidden(UnmanagedEntry& entry) {
  NSWindow* own = entry.own_window ? entry.own_window : (entry.browser ? WindowOfBrowser(entry.browser) : nil);
  std::vector<__weak NSWindow*> windows = std::move(entry.provisionally_hidden);
  entry.provisionally_hidden.clear();
  if (windows.empty()) {
    return;
  }
  // Later, so the browser's own window, if it was never named, has closed
  // and left NSApp.windows by then.
  __weak NSWindow* weak_own = own;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    NSArray<NSWindow*>* open = NSApp.windows;
    for (NSWindow* window : windows) {
      if (window && window != weak_own && [open containsObject:window]) {
        window.alphaValue = 1;
        window.ignoresMouseEvents = NO;
      }
    }
  });
}

void CloseUnmanaged(int identifier) {
  CEF_REQUIRE_UI_THREAD();
  auto it = UnmanagedEntries().find(identifier);
  if (it == UnmanagedEntries().end() || it->second.close_requested) {
    return;
  }
  UnmanagedEntry& entry = it->second;
  HideOwnWindow(entry);
  // Chromium has shown it by now; take it off screen as well.
  [entry.own_window orderOut:nil];
  entry.close_requested = true;
  entry.browser->GetHost()->CloseBrowser(/*force_close=*/true);
  CefPostDelayedTask(TID_UI, new BlockTask(^{
    auto late = UnmanagedEntries().find(identifier);
    if (late == UnmanagedEntries().end()) {
      return;
    }
    NSLog(@"Browser: a Chrome-style window Chromium opened on its own has not closed");
    HideOwnWindow(late->second);
    [late->second.own_window orderOut:nil];
    // Restoring the provisional hides needs the browser's own window named;
    // without it they stay hidden until the browser closes, rather than risk
    // showing that window again.
    if (late->second.own_window) {
      RestoreProvisionallyHidden(late->second);
    }
  }), (int64_t)(kUnmanagedActivationGuardSeconds * 1000));
}

bool IsReportableURL(const std::string& url) {
  return !url.empty() && url != "about:blank";
}

// Takes every browser GetDefaultClient is asked for. Chromium makes those for
// a Chrome-style window of its own, which the app does not own, which takes
// focus, and whose presence at quit crashes shutdown. None may survive, so
// this client cancels every navigation, then closes the browser.
//
// The close is posted rather than done in OnAfterCreated: extension code that
// creates the window (windows.create, openOptionsPage) still holds the Chrome
// Browser and goes on to add the tab and Show() it in the same task, so
// closing inside the callback would free the tab under that caller. By the
// next UI task that code has returned.
class UnmanagedClient : public CefClient, public CefLifeSpanHandler, public CefRequestHandler {
 public:
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    const int identifier = browser->GetIdentifier();
    UnmanagedEntry& entry = UnmanagedEntries()[identifier];
    entry.browser = browser;
    entry.has_profile = BRWProfileIdForRequestContext(browser->GetHost()->GetRequestContext(), &entry.profile_id);
    entry.created_at = CFAbsoluteTimeGetCurrent();
    ExtendActivationGuard(entry.created_at, entry.created_at + kUnmanagedActivationGuardSeconds);
    NSLog(@"Browser: closing a Chrome-style window that Chromium opened on its own");
    // Chromium has made the window but not shown it yet; it shows it later in
    // this same task. Making it transparent now keeps it from ever being
    // seen. When CEF cannot name the window yet, every window that could be
    // it is made transparent for one task: Chromium's own browser-window
    // class, not on screen and not minimized (a minimized window is not
    // visible either, and is not new). The close task restores all but the
    // browser's own.
    HideOwnWindow(entry);
    if (!entry.own_window_hidden) {
      for (NSWindow* window in NSApp.windows) {
        if (!window.isVisible && !window.isMiniaturized && window.alphaValue > 0 &&
            [NSStringFromClass([window class]) isEqualToString:@"BrowserNativeWidgetWindow"]) {
          MakeTransparent(window);
          entry.provisionally_hidden.push_back(window);
        }
      }
    }
    CefPostTask(TID_UI, new BlockTask(^{
      CloseUnmanaged(identifier);
    }));
  }

  bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     int popup_id,
                     const CefString& target_url,
                     const CefString& target_frame_name,
                     WindowOpenDisposition target_disposition,
                     bool user_gesture,
                     const CefPopupFeatures& popupFeatures,
                     CefWindowInfo& windowInfo,
                     CefRefPtr<CefClient>& client,
                     CefBrowserSettings& settings,
                     CefRefPtr<CefDictionaryValue>& extra_info,
                     bool* no_javascript_access) override {
    return true;
  }

  bool DoClose(CefRefPtr<CefBrowser> browser) override { return false; }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    auto it = UnmanagedEntries().find(browser->GetIdentifier());
    if (it == UnmanagedEntries().end()) {
      return;
    }
    // The browser's own window is closing with it; the others go back.
    RestoreProvisionallyHidden(it->second);
    const UnmanagedEntry entry = it->second;
    UnmanagedEntries().erase(it);
    // With no other stray window open, the guard ends shortly after this
    // close, and the rest of its time goes back to the budget.
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (UnmanagedEntries().empty()) {
      ShortenActivationGuard(now + kActivationGuardAfterCloseSeconds);
    }
    ExtendActivationGuard(now, now + kActivationGuardAfterCloseSeconds);
    NSString* url = IsReportableURL(entry.url) ? [NSString stringWithUTF8String:entry.url.c_str()] : nil;
    NSString* profile_id = entry.has_profile ? [NSString stringWithUTF8String:entry.profile_id.c_str()] : nil;
    // Not from inside CEF's close callback: the app answers by creating a
    // browser of its own.
    dispatch_async(dispatch_get_main_queue(), ^{
      id<BRWExtensionRuntimeDelegate> delegate = g_delegate;
      if ([delegate respondsToSelector:@selector(extensionRuntimeDidCloseUnmanagedBrowserWithURL:profileId:)]) {
        [delegate extensionRuntimeDidCloseUnmanagedBrowserWithURL:url profileId:profile_id];
      }
    });
  }

  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                      CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request,
                      bool user_gesture,
                      bool is_redirect) override {
    CEF_REQUIRE_UI_THREAD();
    auto it = UnmanagedEntries().find(browser->GetIdentifier());
    if (it == UnmanagedEntries().end()) {
      return true;
    }
    HideOwnWindow(it->second);
    const std::string url = request->GetURL().ToString();
    if (frame->IsMain() && it->second.url.empty() && IsReportableURL(url)) {
      it->second.url = url;
    }
    return true;
  }

 private:
  IMPLEMENT_REFCOUNTING(UnmanagedClient);
};

}  // namespace

bool BRWExtensionsShouldSuppressActivation() {
  return CFAbsoluteTimeGetCurrent() < g_activation_guard_until;
}

void BRWExtensionsNoteEngineContextInitialized() {
  g_engine_context_initialized = true;
}

void BRWExtensionsAppendLoadExtensionSwitch(CefRefPtr<CefCommandLine> command_line) {
  LoadExtensionSwitchConsumed() = true;
  if (!g_keep_external_extension_switches) {
    // Anything that can launch the app can pass these, and what they load
    // would bypass the shim, the policy and consent, in the user's real
    // profiles. Only the app's own folders, added below, may load.
    CefCommandLine::SwitchMap switches;
    command_line->GetSwitches(switches);
    for (const auto& entry : switches) {
      const std::string name = entry.first.ToString();
      if (IsExtensionLoadingSwitch(name)) {
        NSLog(@"Browser: ignoring --%s, which the app did not add", name.c_str());
        command_line->RemoveSwitch(name);
      }
    }
  }
  if (LoadExtensionPaths().empty() && !command_line->HasSwitch("load-extension")) {
    return;
  }
  // A folder that is missing or has no manifest is a load error, which
  // Chromium otherwise reports in a modal dialog with a nested run loop. The
  // first profile to load decides for the whole process, so this has to be
  // on the command line before CefInitialize.
  if (!command_line->HasSwitch("noerrdialogs")) {
    command_line->AppendSwitch("noerrdialogs");
  }
  std::string value = command_line->GetSwitchValue("load-extension").ToString();
  // Exact duplicates of a folder already named would load nothing new.
  std::vector<std::string> existing;
  if (!value.empty()) {
    size_t start = 0;
    size_t comma;
    while ((comma = value.find(',', start)) != std::string::npos) {
      existing.push_back(value.substr(start, comma - start));
      start = comma + 1;
    }
    existing.push_back(value.substr(start));
  }
  size_t added = 0;
  for (const std::string& path : LoadExtensionPaths()) {
    if (path.find(',') != std::string::npos) {
      NSLog(@"Browser: not loading an extension folder whose path contains a comma: %s", path.c_str());
      continue;
    }
    if (std::find(existing.begin(), existing.end(), path) != existing.end()) {
      continue;
    }
    if (!value.empty()) {
      value += ",";
    }
    value += path;
    existing.push_back(path);
    added++;
  }
  if (added > 0) {
    command_line->AppendSwitchWithValue("load-extension", value);
  }
}

namespace {

// A redirect into the bridge would let the server an extension fetched choose
// the request (its kind and URL), sent with the extension's identity: after a
// redirect CEF runs the request through the handler, or the scheme handler
// factory, again with the original initiator and site. A request that was
// redirected has been on the network first, and the network stack added an
// Accept-Encoding header that the restarted request keeps (observed: present
// on a redirected request, absent on a direct one). Page script cannot set
// that header (it is a forbidden request header), so a direct bridge request
// never has it. BRWClientHandler::OnResourceRedirect also turns a redirect to
// the bridge host into kRedirectRefusedPath, for the requests it sees.
bool ArrivedByRedirect(CefRefPtr<CefRequest> request) {
  return !request->GetHeaderByName("Accept-Encoding").empty();
}

// The answer to one request for the bridge host, or nullptr for any other
// host. `initiator` is the requesting origin as Chromium serializes it.
CefRefPtr<BridgeResourceHandler> MakeBridgeHandler(const std::string& profile_id,
                                                   CefRefPtr<CefRequest> request,
                                                   const std::string& initiator) {
  CefURLParts parts;
  if (!CefParseURL(request->GetURL(), parts)) {
    return nullptr;
  }
  if (ToLowerASCII(CefString(&parts.host).ToString()) != kBridgeHost) {
    return nullptr;
  }
  std::string extension_id;
  const bool from_extension = ExtensionIdFromInitiator(initiator, &extension_id);
  const std::string allow_origin = from_extension ? "chrome-extension://" + extension_id : std::string();
  CefRefPtr<BridgeResourceHandler> handler;
  std::string kind;
  if (!from_extension || profile_id.empty() || ArrivedByRedirect(request) ||
      CefString(&parts.path).ToString() == kRedirectRefusedPath) {
    handler = BridgeResourceHandler::Unresolvable();
  } else if (ToLowerASCII(CefString(&parts.scheme).ToString()) != "https" ||
             !KindFromPath(CefString(&parts.path).ToString(), &kind)) {
    handler = new BridgeResourceHandler(404, ErrorJSON("not found"), allow_origin);
  } else {
    handler = new BridgeResourceHandler(profile_id, extension_id, kind);
  }
  return handler;
}

// CEF consults a context's CefRequestContextHandler only for requests from a
// render process that hosts a frame of one of the app's CefBrowsers. An
// extension's service worker runs in the extension's own process, which has
// no such frame unless one of the extension's pages is open in a tab, so its
// requests skip the handler. A scheme handler factory is per context, not per
// process, so it catches them. It is not told the request initiator; see
// InitiatorFromRequest.
class BridgeSchemeHandlerFactory : public CefSchemeHandlerFactory {
 public:
  explicit BridgeSchemeHandlerFactory(std::string profile_id) : profile_id_(std::move(profile_id)) {}

  CefRefPtr<CefResourceHandler> Create(CefRefPtr<CefBrowser> browser,
                                       CefRefPtr<CefFrame> frame,
                                       const CefString& scheme_name,
                                       CefRefPtr<CefRequest> request) override {
    CefRefPtr<BridgeResourceHandler> handler = MakeBridgeHandler(profile_id_, request, InitiatorFromRequest(request));
    if (!handler) {
      // Registered for the bridge host only, so this is unreachable; still,
      // never let the request fall through to the network.
      handler = BridgeResourceHandler::Unresolvable();
    }
    return handler;
  }

 private:
  // The factory is not given the request initiator, so the extension is read
  // from the request's site for cookies, which Chromium sets to the top-level
  // document's origin, and for a service worker to the worker's own origin:
  // `chrome-extension://<id>/` for an extension's worker or an extension's
  // own top-level document (an offscreen document, for one). A frame of
  // another origin inside such a document shares that site, so the Origin
  // header must not name any other origin: Chromium sends `null` for an
  // extension worker's request, and a cross-origin frame sends its own.
  static std::string InitiatorFromRequest(CefRefPtr<CefRequest> request) {
    std::string site = request->GetFirstPartyForCookies().ToString();
    if (!site.empty() && site.back() == '/') {
      site.pop_back();
    }
    std::string extension_id;
    if (!ExtensionIdFromInitiator(site, &extension_id)) {
      return std::string();
    }
    const std::string origin = request->GetHeaderByName("Origin").ToString();
    if (!origin.empty() && origin != "null" && origin != site) {
      return std::string();
    }
    return site;
  }

  const std::string profile_id_;
  IMPLEMENT_REFCOUNTING(BridgeSchemeHandlerFactory);
};

}  // namespace

CefRefPtr<CefResourceRequestHandler> BRWExtensionBridgeHandlerForRequest(const std::string& profile_id,
                                                                         CefRefPtr<CefRequest> request,
                                                                         const CefString& request_initiator,
                                                                         bool& disable_default_handling) {
  CefRefPtr<BridgeResourceHandler> handler = MakeBridgeHandler(profile_id, request, request_initiator.ToString());
  if (!handler) {
    return nullptr;
  }
  disable_default_handling = true;
  return new BridgeResourceRequestHandler(handler);
}

bool BRWIsExtensionBridgeURL(const CefString& url) {
  CefURLParts parts;
  return CefParseURL(url, parts) && ToLowerASCII(CefString(&parts.host).ToString()) == kBridgeHost;
}

std::string BRWExtensionBridgeRedirectRefusedURL() {
  return std::string("https://") + kBridgeHost + kRedirectRefusedPath;
}

void BRWRegisterExtensionBridgeSchemeHandler(CefRefPtr<CefRequestContext> context, const std::string& profile_id) {
  context->RegisterSchemeHandlerFactory("https", kBridgeHost, new BridgeSchemeHandlerFactory(profile_id));
  context->RegisterSchemeHandlerFactory("http", kBridgeHost, new BridgeSchemeHandlerFactory(profile_id));
}

CefRefPtr<CefRequestContextHandler> BRWCreateExtensionContextHandler(const std::string& profile_id) {
  return new ExtensionContextHandler(profile_id);
}

CefRefPtr<CefClient> BRWUnmanagedBrowserClient() {
  static CefRefPtr<CefClient> client = new UnmanagedClient();
  return client;
}

size_t BRWUnmanagedBrowserLiveCount() {
  return UnmanagedEntries().size();
}

void BRWCloseUnmanagedBrowsers() {
  std::vector<int> identifiers;
  for (const auto& entry : UnmanagedEntries()) {
    identifiers.push_back(entry.first);
  }
  for (int identifier : identifiers) {
    CloseUnmanaged(identifier);
  }
}

@implementation BRWExtensionRuntime

+ (BOOL)setLoadExtensionPaths:(NSArray<NSString *> *)paths {
  if (LoadExtensionSwitchConsumed()) {
    NSLog(@"Browser: extension folders set after CEF started are not loaded until the next launch");
    return NO;
  }
  LoadExtensionPaths().clear();
  for (NSString *path in paths) {
    LoadExtensionPaths().push_back(ToStdString(path));
  }
  return YES;
}

+ (BOOL)setKeepsExternalExtensionSwitches:(BOOL)keep {
  if (LoadExtensionSwitchConsumed()) {
    return NO;
  }
  g_keep_external_extension_switches = keep;
  return YES;
}

+ (id<BRWExtensionRuntimeDelegate>)delegate {
  return g_delegate;
}

+ (void)setDelegate:(id<BRWExtensionRuntimeDelegate>)delegate {
  g_delegate = delegate;
}

+ (NSTimeInterval)requestTimeout {
  return g_request_timeout;
}

+ (void)setRequestTimeout:(NSTimeInterval)requestTimeout {
  g_request_timeout = requestTimeout > 0 ? requestTimeout : 10.0;
}

+ (NSString *)bridgeOrigin {
  return [@"https://" stringByAppendingString:@(kBridgeHost)];
}

+ (BOOL)engineContextInitialized {
  return g_engine_context_initialized;
}

+ (BOOL)isProfileContextInitialized:(NSString *)profileId {
  return InitializedProfileContexts().count(ToStdString(profileId)) > 0;
}

+ (void)initializeProfileContextWithId:(NSString *)profileId completion:(void (^)(void))completion {
  const std::string profile_id = ToStdString(profileId);
  if (profile_id.empty()) {
    return;
  }
  if (InitializedProfileContexts().count(profile_id) > 0) {
    if (completion) {
      dispatch_async(dispatch_get_main_queue(), completion);
    }
    return;
  }
  if (completion) {
    PendingContextCompletions()[profile_id].push_back([completion copy]);
  }
  BRWGetOrCreateProfileContext(profile_id);
}

@end
