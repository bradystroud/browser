#import "BRWDevToolsHandler.h"

#include <cmath>
#include <cstring>
#include <vector>

#include "include/cef_browser.h"
#include "include/cef_parser.h"
#include "include/cef_request_context.h"
#include "include/wrapper/cef_helpers.h"

#import "BRWClientHandler.h"
#import "BRWDevToolsShared.h"
#import "BRWStringUtil.h"

namespace {
// Every DevTools handler constructed but not yet OnBeforeClose'd. UI thread
// (== main thread) only, like BRWClientHandler's own registry.
std::set<BRWDevToolsHandler*>& Registry() {
  static std::set<BRWDevToolsHandler*> registry;
  return registry;
}

// The front-end shares the inspected browser's one DevTools session with the
// bridge's own ExecuteDevToolsMethod calls (responsive design mode), whose
// ids CEF numbers from 1 -- as does the front-end. Front-end ids are shifted
// into their own range on the way out and back on the way in, and the
// bridge's own requests from this file use a third range, so a response
// always reaches whoever asked.
constexpr long long kFrontendIdOffset = 1000000000;
constexpr long long kBridgeIdBase = 2000000000;

// Protocol commands a front-end may not send: anything that reaches past the
// inspected tab -- to another target, to a new one, or to the browser.
bool IsBlockedMethod(const std::string& method) {
  static const std::set<std::string> blocked = {
      "Target.attachToBrowserTarget", "Target.attachToTarget",    "Target.createTarget",
      "Target.closeTarget",           "Target.exposeDevToolsProtocol",
      "Target.createBrowserContext",  "Target.disposeBrowserContext",
      "Target.getBrowserContexts",    "Target.setRemoteLocations",
  };
  if (blocked.count(method)) {
    return true;
  }
  return method.rfind("Browser.", 0) == 0 && method != "Browser.getVersion";
}

const char* PanelId(BRWDevToolsPanel panel) {
  switch (panel) {
    case BRWDevToolsPanelElements:
      return "elements";
    case BRWDevToolsPanelConsole:
      return "console";
    case BRWDevToolsPanelSources:
      return "sources";
    case BRWDevToolsPanelNetwork:
      return "network";
    case BRWDevToolsPanelDefault:
      return "";
  }
  return "";
}

const char kLogPrefix[] = "BRWDevTools:";

// Parses the `{"id":N` a protocol message starts with when it is a command
// or a response (Chromium's serializer and the front-end's JSON.stringify
// both put "id" first). Returns false for events and anything unexpected.
bool ParseLeadingId(const char* data, size_t size, long long* id, size_t* digits_end) {
  static const char kPrefix[] = "{\"id\":";
  const size_t prefix_length = sizeof(kPrefix) - 1;
  if (size <= prefix_length || std::memcmp(data, kPrefix, prefix_length) != 0) {
    return false;
  }
  size_t i = prefix_length;
  long long value = 0;
  while (i < size && data[i] >= '0' && data[i] <= '9' && i < prefix_length + 12) {
    value = value * 10 + (data[i] - '0');
    ++i;
  }
  if (i == prefix_length) {
    return false;
  }
  *id = value;
  *digits_end = i;
  return true;
}

std::string WithId(long long id, const char* data, size_t size, size_t digits_end) {
  std::string result = "{\"id\":" + std::to_string(id);
  result.append(data + digits_end, size - digits_end);
  return result;
}

std::string ToJSON(CefRefPtr<CefValue> value) {
  return CefWriteJSON(value, JSON_WRITER_DEFAULT).ToString();
}

std::string ToJSON(CefRefPtr<CefDictionaryValue> dictionary) {
  CefRefPtr<CefValue> value = CefValue::Create();
  value->SetDictionary(dictionary);
  return ToJSON(value);
}

// A JS/JSON string literal for `text`.
std::string Quoted(const std::string& text) {
  CefRefPtr<CefValue> value = CefValue::Create();
  value->SetString(text);
  return ToJSON(value);
}

bool IsWebURL(const std::string& url) {
  return url.rfind("http://", 0) == 0 || url.rfind("https://", 0) == 0 ||
         url.rfind("file://", 0) == 0;
}

void NotifyDelegate(BRWClientHandler* owner, bool opened) {
  __weak id<BRWBrowserDelegate> delegate = owner ? owner->GetDelegate() : nil;
  // Deferred, so a delegate that reacts by calling back into BRWBrowser
  // never re-enters CEF from inside Show() or a CEF close callback.
  dispatch_async(dispatch_get_main_queue(), ^{
    id<BRWBrowserDelegate> strong = delegate;
    if (opened) {
      if ([strong respondsToSelector:@selector(browserDevToolsDidOpen)]) {
        [strong browserDevToolsDidOpen];
      }
    } else if ([strong respondsToSelector:@selector(browserDevToolsDidClose)]) {
      [strong browserDevToolsDidClose];
    }
  });
}

void ForwardNewTab(BRWClientHandler* owner, const std::string& url) {
  if (!IsWebURL(url)) {
    return;
  }
  id<BRWBrowserDelegate> delegate = owner ? owner->GetDelegate() : nil;
  if ([delegate respondsToSelector:@selector(browserDidRequestNewTabForURL:disposition:)]) {
    [delegate browserDidRequestNewTabForURL:[NSString stringWithUTF8String:url.c_str()]
                                disposition:BRWWindowOpenDispositionForegroundTab];
  }
}

// DevTools preferences, one dictionary per profile directory, shared by every
// front-end of that profile and written back to disk a second after the last
// change. Values are the strings the front-end hands over, stored verbatim.
std::map<std::string, CefRefPtr<CefDictionaryValue>>& LoadedPreferences() {
  static std::map<std::string, CefRefPtr<CefDictionaryValue>> loaded;
  return loaded;
}

std::set<std::string>& PendingPreferenceWrites() {
  static std::set<std::string> pending;
  return pending;
}

CefRefPtr<CefDictionaryValue> LoadPreferences(const std::string& path) {
  auto& loaded = LoadedPreferences();
  auto it = loaded.find(path);
  if (it != loaded.end()) {
    return it->second;
  }
  CefRefPtr<CefDictionaryValue> preferences;
  NSData* data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path.c_str()]];
  if (data.length > 0) {
    CefRefPtr<CefValue> parsed = CefParseJSON(data.bytes, data.length, JSON_PARSER_RFC);
    if (parsed && parsed->GetType() == VTYPE_DICTIONARY) {
      preferences = parsed->GetDictionary()->Copy(false);
    }
  }
  if (!preferences) {
    preferences = CefDictionaryValue::Create();
  }
  loaded[path] = preferences;
  return preferences;
}

void WritePreferences(const std::string& path) {
  auto it = LoadedPreferences().find(path);
  if (it == LoadedPreferences().end()) {
    return;
  }
  const std::string json = ToJSON(it->second);
  NSData* data = [NSData dataWithBytes:json.data() length:json.size()];
  [data writeToFile:[NSString stringWithUTF8String:path.c_str()] atomically:YES];
}

void SchedulePreferencesWrite(const std::string& path) {
  if (!PendingPreferenceWrites().insert(path).second) {
    return;
  }
  const std::string captured = path;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    PendingPreferenceWrites().erase(captured);
    WritePreferences(captured);
  });
}
}  // namespace

BRWDevToolsHandler::BRWDevToolsHandler(BRWClientHandler* owner, NSView* container)
    : owner_(owner), embedded_(container != nil), container_(container) {
  Registry().insert(this);
}

BRWDevToolsHandler::~BRWDevToolsHandler() = default;

// static
void BRWDevToolsHandler::Show(BRWClientHandler* owner, const Request& request) {
  CEF_REQUIRE_UI_THREAD();
  if (!owner || !owner->browser_ || owner->closed_ || owner->close_requested_ ||
      owner->pending_close_) {
    return;
  }
  NSView* container = request.container;
  if (container) {
    owner->last_devtools_container_ = container;
  }
  CefRefPtr<CefBrowserHost> inspected_host = owner->browser_->GetHost();

  CefRefPtr<BRWDevToolsHandler> existing = owner->devtools_;
  if (existing) {
    if (existing->close_requested_ || existing->pending_close_ ||
        existing->embedded_ != (container != nil)) {
      // Can't be satisfied by this instance: it is on its way out, or lives
      // in the wrong kind of place (CEF's window can't be adopted into our
      // view, nor the reverse). Replayed once it has fully closed.
      existing->has_reopen_ = true;
      existing->reopen_ = request;
      existing->RequestClose();
      return;
    }
    if (existing->embedded_) {
      if (container != existing->container_) {
        existing->MoveTo(container);
      }
      if (existing->browser_) {
        existing->browser_->GetHost()->SetFocus(true);
      }
      existing->QueueAction(request);
    } else {
      // CEF focuses its window and still honours the point.
      const CefPoint point = request.has_point ? CefPoint(request.x, request.y) : CefPoint();
      inspected_host->ShowDevTools(CefWindowInfo(), nullptr, CefBrowserSettings(), point);
      existing->QueueAction(request);
    }
    return;
  }

  CefRefPtr<BRWDevToolsHandler> handler = new BRWDevToolsHandler(owner, container);
  owner->devtools_ = handler;
  handler->QueueAction(request);

  bool created = false;
  if (container) {
    CefRefPtr<CefRequestContext> context = inspected_host->GetRequestContext();
    const std::string cache_path = context ? context->GetCachePath().ToString() : "";
    if (!cache_path.empty()) {
      handler->preferences_path_ = cache_path + "/devtools-preferences.json";
    }

    CefWindowInfo window_info;
    CefRect bounds(0, 0, (int)container.bounds.size.width, (int)container.bounds.size.height);
    window_info.SetAsChild((__bridge void*)container, bounds);
    window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    CefBrowserSettings settings;
    CefRefPtr<CefDictionaryValue> extra_info = CefDictionaryValue::Create();
    extra_info->SetBool(kBRWDevToolsFrontendExtraInfoKey, true);
    created = CefBrowserHost::CreateBrowser(window_info, handler, kBRWDevToolsFrontendURL,
                                            settings, extra_info, context);
    if (created) {
      handler->observer_registration_ = inspected_host->AddDevToolsMessageObserver(handler);
    }
  } else {
    const CefPoint point = request.has_point ? CefPoint(request.x, request.y) : CefPoint();
    inspected_host->ShowDevTools(CefWindowInfo(), handler, CefBrowserSettings(), point);
    created = handler->browser_ || inspected_host->HasDevTools();
  }

  if (!created) {
    // Nothing will ever deliver OnBeforeClose for this handler, so it must
    // not stay registered -- LiveCount() would otherwise hold up shutdown.
    Registry().erase(handler.get());
    handler->closed_ = true;
    handler->owner_ = nullptr;
    owner->devtools_ = nullptr;
    return;
  }
  NotifyDelegate(owner, /*opened=*/true);
}

// static
void BRWDevToolsHandler::Close(BRWClientHandler* owner) {
  CEF_REQUIRE_UI_THREAD();
  if (!owner || !owner->devtools_) {
    return;
  }
  CefRefPtr<BRWDevToolsHandler> devtools = owner->devtools_;
  devtools->has_reopen_ = false;
  devtools->RequestClose();
}

// static
bool BRWDevToolsHandler::IsOpen(BRWClientHandler* owner) {
  if (!owner || !owner->devtools_) {
    return false;
  }
  const BRWDevToolsHandler* devtools = owner->devtools_.get();
  if (devtools->closed_) {
    return false;
  }
  return devtools->has_reopen_ || !(devtools->close_requested_ || devtools->pending_close_);
}

// static
size_t BRWDevToolsHandler::LiveCount() {
  return Registry().size();
}

// static
void BRWDevToolsHandler::CloseAll() {
  CEF_REQUIRE_UI_THREAD();
  std::vector<CefRefPtr<BRWDevToolsHandler>> handlers(Registry().begin(), Registry().end());
  for (const CefRefPtr<BRWDevToolsHandler>& handler : handlers) {
    handler->has_reopen_ = false;
    handler->RequestClose();
  }
}

void BRWDevToolsHandler::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  browser_ = browser;
  if (pending_close_) {
    pending_close_ = false;
    RequestClose();
    return;
  }
  if (embedded_) {
    AttachViewToContainer();
  }
}

void BRWDevToolsHandler::AttachViewToContainer() {
  if (!browser_) {
    return;
  }
  NSView* view = (__bridge NSView*)(void*)browser_->GetHost()->GetWindowHandle();
  NSView* container = container_;
  if (view == nil) {
    return;
  }
  if (container == nil) {
    // The container went away before the browser finished being created.
    RequestClose();
    return;
  }
  if (view.superview != container) {
    [container addSubview:view];
  }
  view.frame = container.bounds;
  view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
}

void BRWDevToolsHandler::MoveTo(NSView* container) {
  container_ = container;
  AttachViewToContainer();
}

void BRWDevToolsHandler::RequestClose() {
  CEF_REQUIRE_UI_THREAD();
  if (closed_ || close_requested_) {
    return;
  }
  if (!browser_) {
    pending_close_ = true;
    return;
  }
  close_requested_ = true;

  CefRefPtr<BRWClientHandler> owner = owner_;
  const bool inspected_alive = owner && owner->browser_ && !owner->closed_ && !owner->close_requested_;

  if (!embedded_) {
    if (inspected_alive) {
      // The inspected browser's own call, so CEF's DevTools manager tears
      // its side down in its usual order.
      owner->browser_->GetHost()->CloseDevTools();
    } else {
      browser_->GetHost()->CloseBrowser(/*force_close=*/true);
    }
    return;
  }

  if (inspected_alive) {
    ResetInspectedPageState();
  }
  observer_registration_ = nullptr;
  NSView* view = (__bridge NSView*)(void*)browser_->GetHost()->GetWindowHandle();
  [view removeFromSuperview];
  browser_->GetHost()->CloseBrowser(/*force_close=*/true);
}

bool BRWDevToolsHandler::DoClose(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  if (embedded_ && browser_) {
    close_requested_ = true;
    observer_registration_ = nullptr;
    NSView* view = (__bridge NSView*)(void*)browser_->GetHost()->GetWindowHandle();
    [view removeFromSuperview];
  }
  return false;
}

void BRWDevToolsHandler::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  closed_ = true;
  browser_ = nullptr;
  observer_registration_ = nullptr;
  Registry().erase(this);
  // Written now rather than on the debounce timer, which may never fire if
  // this close is part of quitting.
  if (!preferences_path_.empty() && PendingPreferenceWrites().erase(preferences_path_)) {
    WritePreferences(preferences_path_);
  }

  CefRefPtr<BRWClientHandler> owner = owner_;
  owner_ = nullptr;
  if (!owner) {
    return;
  }
  if (owner->devtools_.get() == this) {
    owner->devtools_ = nullptr;
  }
  NotifyDelegate(owner.get(), /*opened=*/false);
  if (has_reopen_) {
    has_reopen_ = false;
    const Request request = reopen_;
    dispatch_async(dispatch_get_main_queue(), ^{
      BRWDevToolsHandler::Show(owner.get(), request);
    });
  }
}

bool BRWDevToolsHandler::OnBeforePopup(CefRefPtr<CefBrowser> browser,
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
                                       bool* no_javascript_access) {
  CEF_REQUIRE_UI_THREAD();
  ForwardNewTab(owner_.get(), target_url.ToString());
  return true;
}

bool BRWDevToolsHandler::OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                                        CefRefPtr<CefFrame> frame,
                                        CefRefPtr<CefRequest> request,
                                        bool user_gesture,
                                        bool is_redirect) {
  if (!embedded_ || !frame->IsMain()) {
    return false;
  }
  const std::string url = request->GetURL().ToString();
  if (url.rfind(kBRWDevToolsFrontendOrigin, 0) == 0) {
    return false;
  }
  if (user_gesture) {
    ForwardNewTab(owner_.get(), url);
  }
  return true;
}

bool BRWDevToolsHandler::OnOpenURLFromTab(CefRefPtr<CefBrowser> browser,
                                          CefRefPtr<CefFrame> frame,
                                          const CefString& target_url,
                                          WindowOpenDisposition target_disposition,
                                          bool user_gesture) {
  CEF_REQUIRE_UI_THREAD();
  if (target_disposition == CEF_WOD_CURRENT_TAB) {
    return false;
  }
  ForwardNewTab(owner_.get(), target_url.ToString());
  return true;
}

void BRWDevToolsHandler::OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                                   TerminationStatus status,
                                                   int error_code,
                                                   const CefString& error_string) {
  RequestClose();
}

void BRWDevToolsHandler::OnLoadStart(CefRefPtr<CefBrowser> browser,
                                     CefRefPtr<CefFrame> frame,
                                     TransitionType transition_type) {
  if (!embedded_ || !frame->IsMain()) {
    return;
  }
  // A (re)loaded front-end starts over; actions wait for its loadCompleted.
  frontend_ready_ = false;
  const double zoom = std::pow(1.2, browser->GetHost()->GetZoomLevel());
  CallFrontend("window.DevToolsHost && DevToolsHost._setZoomFactor(" + std::to_string(zoom) + ");");
}

bool BRWDevToolsHandler::OnConsoleMessage(CefRefPtr<CefBrowser> browser,
                                          cef_log_severity_t level,
                                          const CefString& message,
                                          const CefString& source,
                                          int line) {
  const std::string text = message.ToString();
  if (text.rfind(kLogPrefix, 0) == 0) {
    NSLog(@"Browser: %s", text.c_str());
  }
  return false;
}

bool BRWDevToolsHandler::OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                                  CefRefPtr<CefFrame> frame,
                                                  CefProcessId source_process,
                                                  CefRefPtr<CefProcessMessage> message) {
  CEF_REQUIRE_UI_THREAD();
  if (message->GetName() != kBRWDevToolsEmbedderMessage) {
    return false;
  }
  if (!embedded_ || !browser_ || close_requested_ || !browser->IsSame(browser_) || !frame ||
      !frame->IsMain() ||
      frame->GetURL().ToString().rfind(kBRWDevToolsFrontendOrigin, 0) != 0) {
    return true;  // Ours by name, but not from our front-end: dropped.
  }
  HandleEmbedderMessage(message->GetArgumentList()->GetString(0).ToString());
  return true;
}

// The embedder side of devtools_compatibility.js. Methods whose front-end
// call passes a callback get an embedderMessageAck; everything else is
// fire-and-forget, as it is in Chrome.
void BRWDevToolsHandler::HandleEmbedderMessage(const std::string& json) {
  CefRefPtr<CefValue> parsed = CefParseJSON(json, JSON_PARSER_RFC);
  if (!parsed || parsed->GetType() != VTYPE_DICTIONARY) {
    return;
  }
  CefRefPtr<CefDictionaryValue> message = parsed->GetDictionary();
  const int call_id = message->GetInt("id");
  const std::string method = message->GetString("method").ToString();
  CefRefPtr<CefListValue> params =
      message->HasKey("params") ? message->GetList("params") : CefListValue::Create();
  if (!params) {
    params = CefListValue::Create();
  }
  auto param_string = [&](size_t i) -> std::string {
    return i < params->GetSize() && params->GetType(i) == VTYPE_STRING ? params->GetString(i).ToString()
                                                                       : std::string();
  };
  auto param_bool = [&](size_t i) -> bool {
    return i < params->GetSize() && params->GetType(i) == VTYPE_BOOL && params->GetBool(i);
  };

  if (method == "dispatchProtocolMessage") {
    DispatchProtocolMessageFromFrontend(param_string(0));
  } else if (method == "loadCompleted") {
    frontend_ready_ = true;
    // In-page context menus: the front-end's own, instead of a native menu
    // built from its descriptors.
    CallFrontend("DevToolsAPI.setUseSoftMenu(true);");
    FlushActions();
  } else if (method == "getPreferences") {
    Ack(call_id, ToJSON(Preferences()));
  } else if (method == "getPreference") {
    CefRefPtr<CefDictionaryValue> preferences = Preferences();
    const std::string name = param_string(0);
    Ack(call_id, preferences->HasKey(name) ? Quoted(preferences->GetString(name).ToString()) : "null");
  } else if (method == "setPreference") {
    Preferences()->SetString(param_string(0), param_string(1));
    PreferencesChanged();
  } else if (method == "removePreference") {
    Preferences()->Remove(param_string(0));
    PreferencesChanged();
  } else if (method == "clearPreferences") {
    Preferences()->Clear();
    PreferencesChanged();
  } else if (method == "getHostConfig") {
    // No AIDA/Gemini, no sync, no surveys: none of Google's services exist here.
    CefRefPtr<CefDictionaryValue> config = CefDictionaryValue::Create();
    config->SetBool("isOffTheRecord", preferences_path_.empty());
    Ack(call_id, ToJSON(config));
  } else if (method == "getSyncInformation") {
    Ack(call_id, "{\"isSyncActive\":false,\"arePreferencesSynced\":false}");
  } else if (method == "showSurvey") {
    Ack(call_id, "{\"surveyShown\":false}");
  } else if (method == "canShowSurvey") {
    Ack(call_id, "{\"canShowSurvey\":false}");
  } else if (method == "loadNetworkResource") {
    // Used for source maps and similar the protocol's own
    // Network.loadNetworkResource can't fetch; answered as a failed load.
    Ack(call_id, "{\"statusCode\":0,\"netError\":-2,\"netErrorName\":\"net::ERR_FAILED\",\"urlValid\":true}");
  } else if (method == "dispatchHttpRequest" || method == "doAidaConversation" ||
             method == "aidaCodeComplete" || method == "registerAidaClientEvent") {
    Ack(call_id, "{\"error\":\"Not available in this browser\"}");
  } else if (method == "copyText") {
    NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    [pasteboard setString:[NSString stringWithUTF8String:param_string(0).c_str()] ?: @""
                  forType:NSPasteboardTypeString];
  } else if (method == "openInNewTab" || method == "openSearchResultsInNewTab") {
    ForwardNewTab(owner_.get(), param_string(0));
  } else if (method == "bringToFront") {
    if (browser_) {
      browser_->GetHost()->SetFocus(true);
    }
  } else if (method == "closeWindow") {
    has_reopen_ = false;
    RequestClose();
  } else if (method == "requestRestart") {
    if (browser_) {
      browser_->Reload();
    }
  } else if (method == "zoomIn" || method == "zoomOut" || method == "resetZoom") {
    if (browser_) {
      double level = browser_->GetHost()->GetZoomLevel();
      level = method == "resetZoom" ? 0 : level + (method == "zoomIn" ? 0.5 : -0.5);
      browser_->GetHost()->SetZoomLevel(level);
      CallFrontend("DevToolsHost._setZoomFactor(" + std::to_string(std::pow(1.2, level)) + ");");
    }
  } else if (method == "save") {
    Save(param_string(0), param_string(1), param_bool(2), param_bool(3));
  } else if (method == "append") {
    const std::string url = param_string(0);
    auto it = saved_paths_.find(url);
    if (it != saved_paths_.end()) {
      NSFileHandle* file = [NSFileHandle fileHandleForWritingAtPath:[NSString stringWithUTF8String:it->second.c_str()]];
      const std::string content = param_string(1);
      [file seekToEndOfFile];
      [file writeData:[NSData dataWithBytes:content.data() length:content.size()]];
      [file closeFile];
      CallFrontend("DevToolsAPI.appendedToURL(" + Quoted(url) + ");");
    }
  } else if (method == "requestFileSystems") {
    CallFrontend("DevToolsAPI.fileSystemsLoaded([]);");
  } else if (method == "addFileSystem") {
    CallFrontend("DevToolsAPI.fileSystemAdded(" +
                 Quoted("Workspaces are not supported in this browser.") + ", null);");
  } else if (method == "indexPath") {
    if (params->GetSize() >= 2) {
      CallFrontend("DevToolsAPI.indexingDone(" + std::to_string(params->GetInt(0)) + ", " +
                   Quoted(param_string(1)) + ");");
    }
  } else if (method == "searchInPath") {
    if (params->GetSize() >= 2) {
      CallFrontend("DevToolsAPI.searchCompleted(" + std::to_string(params->GetInt(0)) + ", " +
                   Quoted(param_string(1)) + ", []);");
    }
  } else if (method == "setIsDocked" || method == "reattach") {
    Ack(call_id, "");
  } else if (method.rfind("record", 0) == 0 || method == "registerPreference" ||
             method == "setInspectedPageBounds" || method == "inspectElementCompleted" ||
             method == "inspectedURLChanged" || method == "setWhitelistedShortcuts" ||
             method == "setEyeDropperActive" || method == "readyForTest" ||
             method == "connectionReady" || method == "setOpenNewWindowForPopups" ||
             method == "setDevicesUpdatesEnabled" || method == "setDevicesDiscoveryConfig" ||
             method == "registerExtensionsAPI" || method == "stopIndexing" ||
             method == "removeFileSystem" || method == "showItemInFolder" ||
             method == "setChromeFlag" || method == "showCertificateViewer" ||
             method == "openRemotePage" || method == "openNodeFrontend" ||
             method == "disconnectAutomaticFileSystem" || method == "connectAutomaticFileSystem") {
    // Deliberately unsupported or irrelevant here; nothing to answer.
  } else if (call_id > 0) {
    // Unknown (newer front-end): answer with no value rather than leave a
    // callback hanging.
    Ack(call_id, "");
  }
}

void BRWDevToolsHandler::DispatchProtocolMessageFromFrontend(const std::string& message) {
  CefRefPtr<BRWClientHandler> owner = owner_;
  if (!owner || !owner->browser_ || owner->closed_ || owner->close_requested_) {
    return;
  }
  CefRefPtr<CefValue> parsed = CefParseJSON(message, JSON_PARSER_RFC);
  if (!parsed || parsed->GetType() != VTYPE_DICTIONARY) {
    return;
  }
  CefRefPtr<CefDictionaryValue> command = parsed->GetDictionary();
  const std::string method = command->GetString("method").ToString();
  const bool has_session = command->HasKey("sessionId");

  if (IsBlockedMethod(method)) {
    CefRefPtr<CefDictionaryValue> response = CefDictionaryValue::Create();
    response->SetInt("id", command->GetInt("id"));
    CefRefPtr<CefDictionaryValue> error = CefDictionaryValue::Create();
    error->SetInt("code", -32601);
    error->SetString("message", "'" + method + "' is not available in this browser's DevTools");
    response->SetDictionary("error", error);
    if (has_session) {
      response->SetString("sessionId", command->GetString("sessionId"));
    }
    CallFrontend("DevToolsAPI.dispatchMessage(" + ToJSON(response) + ");");
    return;
  }

  if (!has_session) {
    const size_t dot = method.find('.');
    if (dot != std::string::npos && method.compare(dot, std::string::npos, ".enable") == 0) {
      enabled_domains_.insert(method.substr(0, dot));
    }
  }
  if (method == "Emulation.setDeviceMetricsOverride") {
    used_device_emulation_ = true;
  } else if (method == "Emulation.setCPUThrottlingRate") {
    used_cpu_throttling_ = true;
  } else if (method.rfind("Network.emulateNetworkConditions", 0) == 0) {
    used_network_conditions_ = true;
  }

  long long id = 0;
  size_t digits_end = 0;
  std::string outgoing;
  if (ParseLeadingId(message.data(), message.size(), &id, &digits_end) && id < kFrontendIdOffset) {
    outgoing = WithId(id + kFrontendIdOffset, message.data(), message.size(), digits_end);
  } else {
    // Not the shape the front-end has always sent; re-serialize instead.
    command->SetInt("id", (int)(command->GetInt("id") + kFrontendIdOffset));
    outgoing = ToJSON(command);
  }
  owner->browser_->GetHost()->SendDevToolsMessage(outgoing.data(), outgoing.size());
}

bool BRWDevToolsHandler::OnDevToolsMessage(CefRefPtr<CefBrowser> browser,
                                           const void* message,
                                           size_t message_size) {
  CEF_REQUIRE_UI_THREAD();
  if (!embedded_ || !browser_ || close_requested_) {
    return false;
  }
  const char* data = static_cast<const char*>(message);
  long long id = 0;
  size_t digits_end = 0;
  if (!ParseLeadingId(data, message_size, &id, &digits_end)) {
    // An event -- for a domain the front-end enabled.
    CallFrontend("DevToolsAPI.dispatchMessage(" + std::string(data, message_size) + ");");
    return true;
  }
  if (id >= kBridgeIdBase) {
    auto it = inspect_requests_.find((int)(id - kBridgeIdBase));
    if (it == inspect_requests_.end()) {
      return true;
    }
    const std::pair<int, int> point = it->second;
    const int attempt = inspect_attempts_[it->first];
    inspect_attempts_.erase(it->first);
    inspect_requests_.erase(it);
    CefRefPtr<CefValue> parsed = CefParseJSON(data, message_size, JSON_PARSER_RFC);
    CefRefPtr<CefDictionaryValue> result =
        parsed && parsed->GetType() == VTYPE_DICTIONARY ? parsed->GetDictionary()->GetDictionary("result")
                                                        : nullptr;
    if (result && result->HasKey("backendNodeId")) {
      // What the backend itself emits when the user picks an element in
      // inspect mode; the front-end reveals the node in Elements.
      CallFrontend("DevToolsAPI.showPanel('elements');"
                   "DevToolsAPI.dispatchMessage({\"method\":\"Overlay.inspectNodeRequested\","
                   "\"params\":{\"backendNodeId\":" +
                   std::to_string(result->GetInt("backendNodeId")) + "}});");
    } else if (attempt < 20) {
      // Typically "DOM agent is not enabled" -- the front-end hasn't got
      // that far yet.
      CefRefPtr<BRWDevToolsHandler> self = this;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{
        self->InspectAt(point.first, point.second, attempt + 1);
      });
    }
    return true;
  }
  if (id >= kFrontendIdOffset) {
    CallFrontend("DevToolsAPI.dispatchMessage(" +
                 WithId(id - kFrontendIdOffset, data, message_size, digits_end) + ");");
    return true;
  }
  // A response to someone else's command on this session (the bridge's
  // responsive design mode); not the front-end's business.
  return false;
}

void BRWDevToolsHandler::SendBridgeCommand(int id,
                                           const std::string& method,
                                           CefRefPtr<CefDictionaryValue> params) {
  CefRefPtr<BRWClientHandler> owner = owner_;
  if (!owner || !owner->browser_) {
    return;
  }
  CefRefPtr<CefDictionaryValue> command = CefDictionaryValue::Create();
  command->SetString("method", method);
  command->SetDictionary("params", params ? params : CefDictionaryValue::Create());
  // The id goes in by hand, first: CefDictionaryValue ints are 32-bit.
  const std::string body = ToJSON(command);
  const std::string json = "{\"id\":" + std::to_string(kBridgeIdBase + id) + "," + body.substr(1);
  owner->browser_->GetHost()->SendDevToolsMessage(json.data(), json.size());
}

// Chrome detaches the front-end's session when DevTools closes, which resets
// everything it did to the page. This session is shared and stays attached,
// so undo it by hand: leave inspect mode, resume a paused debugger, stop
// emulation the front-end started, and disable every domain it enabled.
void BRWDevToolsHandler::ResetInspectedPageState() {
  int id = 100000000;  // Fire-and-forget; responses are never looked at.
  if (enabled_domains_.count("Overlay")) {
    CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
    params->SetString("mode", "none");
    params->SetDictionary("highlightConfig", CefDictionaryValue::Create());
    SendBridgeCommand(id++, "Overlay.setInspectMode", params);
    SendBridgeCommand(id++, "Overlay.hideHighlight", nullptr);
  }
  if (used_device_emulation_) {
    SendBridgeCommand(id++, "Emulation.clearDeviceMetricsOverride", nullptr);
  }
  if (used_cpu_throttling_) {
    CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
    params->SetDouble("rate", 1);
    SendBridgeCommand(id++, "Emulation.setCPUThrottlingRate", params);
  }
  if (used_network_conditions_) {
    CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
    params->SetBool("offline", false);
    params->SetDouble("latency", 0);
    params->SetDouble("downloadThroughput", -1);
    params->SetDouble("uploadThroughput", -1);
    SendBridgeCommand(id++, "Network.emulateNetworkConditions", params);
  }
  if (enabled_domains_.count("Network")) {
    CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
    params->SetBool("cacheDisabled", false);
    SendBridgeCommand(id++, "Network.setCacheDisabled", params);
  }
  CefRefPtr<CefDictionaryValue> auto_attach = CefDictionaryValue::Create();
  auto_attach->SetBool("autoAttach", false);
  auto_attach->SetBool("waitForDebuggerOnStart", false);
  SendBridgeCommand(id++, "Target.setAutoAttach", auto_attach);
  for (const std::string& domain : enabled_domains_) {
    SendBridgeCommand(id++, domain + ".disable", nullptr);
  }
  enabled_domains_.clear();
}

void BRWDevToolsHandler::QueueAction(const Request& request) {
  if (!embedded_) {
    return;  // CEF's own window: only the point is supported, via ShowDevTools.
  }
  const std::string panel = PanelId(request.panel);
  if (!panel.empty()) {
    pending_panel_ = panel;
  }
  if (request.start_picker) {
    pending_picker_ = !pending_picker_;
  }
  if (request.has_point) {
    pending_inspect_ = true;
    pending_inspect_x_ = request.x;
    pending_inspect_y_ = request.y;
  }
  if (frontend_ready_) {
    FlushActions();
  }
}

// DevToolsAPI.showPanel / enterInspectElementMode are the embedder API
// Chrome itself uses for "open on the Console panel" and ⌘⇧C. Going through
// the front-end rather than raw CDP (Overlay.setInspectMode) keeps its UI in
// step: the picker's toolbar button lights up, and a pick reveals the node.
// They are plain event dispatches, dropped if nothing listens yet, so the
// script waits (up to 15s) for InspectorFrontendHost.events to report a
// listener -- loadCompleted normally means one is already there.
void BRWDevToolsHandler::FlushActions() {
  if (!browser_ || close_requested_) {
    return;
  }
  std::string actions;
  if (!pending_panel_.empty()) {
    actions += "['showPanel','" + pending_panel_ + "'],";
  }
  if (pending_picker_) {
    actions += "['enterInspectElementMode',''],";
  }
  pending_panel_.clear();
  pending_picker_ = false;
  if (!actions.empty()) {
    CallFrontend(
        "(function () {\n"
        "  const actions = [" + actions + "];\n"
        "  const deadline = Date.now() + 15000;\n"
        "  function ready(action) {\n"
        "    const api = window.DevToolsAPI;\n"
        "    const events = window.InspectorFrontendHost && window.InspectorFrontendHost.events;\n"
        "    if (!api || typeof api[action[0]] !== 'function' || !events) return false;\n"
        "    return typeof events.hasEventListeners !== 'function' || events.hasEventListeners(action[0]);\n"
        "  }\n"
        "  function step() {\n"
        "    while (actions.length && ready(actions[0])) {\n"
        "      const action = actions.shift();\n"
        "      if (action[1]) DevToolsAPI[action[0]](action[1]); else DevToolsAPI[action[0]]();\n"
        "    }\n"
        "    if (!actions.length) return;\n"
        "    if (Date.now() > deadline) {\n"
        "      console.warn('" + std::string(kLogPrefix) + " front-end never became ready for ' + actions[0][0]);\n"
        "      return;\n"
        "    }\n"
        "    setTimeout(step, 50);\n"
        "  }\n"
        "  step();\n"
        "})();\n");
  }
  if (pending_inspect_) {
    pending_inspect_ = false;
    InspectAt(pending_inspect_x_, pending_inspect_y_, 0);
  }
}

// CEF's own inspect-at-point belongs to its DevTools window; here the same
// thing is done by hand. The point is in the inspected view's DIP, which the
// protocol wants in CSS pixels: page zoom is the difference.
void BRWDevToolsHandler::InspectAt(int x, int y, int attempt) {
  CefRefPtr<BRWClientHandler> owner = owner_;
  if (!owner || !owner->browser_ || close_requested_) {
    return;
  }
  const double zoom = std::pow(1.2, owner->browser_->GetHost()->GetZoomLevel());
  const int id = ++next_bridge_id_ % 100000000;
  inspect_requests_[id] = {x, y};
  inspect_attempts_[id] = attempt;
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetInt("x", (int)std::lround(x / zoom));
  params->SetInt("y", (int)std::lround(y / zoom));
  params->SetBool("includeUserAgentShadowDOM", false);
  params->SetBool("ignorePointerEventsNone", true);
  SendBridgeCommand(id, "DOM.getNodeForLocation", params);
}

void BRWDevToolsHandler::Save(const std::string& url,
                              const std::string& content,
                              bool force_save_as,
                              bool is_base64) {
  NSData* data = nil;
  if (is_base64) {
    data = [[NSData alloc] initWithBase64EncodedString:[NSString stringWithUTF8String:content.c_str()]
                                               options:NSDataBase64DecodingIgnoreUnknownCharacters];
  } else {
    data = [NSData dataWithBytes:content.data() length:content.size()];
  }
  auto it = saved_paths_.find(url);
  if (!force_save_as && it != saved_paths_.end()) {
    [data writeToFile:[NSString stringWithUTF8String:it->second.c_str()] atomically:YES];
    CallFrontend("DevToolsAPI.savedURL(" + Quoted(url) + ", " + Quoted(it->second) + ");");
    return;
  }

  NSSavePanel* panel = [NSSavePanel savePanel];
  NSString* name = [[NSURL URLWithString:[NSString stringWithUTF8String:url.c_str()]] lastPathComponent];
  panel.nameFieldStringValue = name.length > 0 ? name : @"download";
  CefRefPtr<BRWDevToolsHandler> self = this;
  const std::string captured_url = url;
  void (^completion)(NSModalResponse) = ^(NSModalResponse response) {
    if (response != NSModalResponseOK || !panel.URL || ![data writeToURL:panel.URL atomically:YES]) {
      self->CallFrontend("DevToolsAPI.canceledSaveURL(" + Quoted(captured_url) + ");");
      return;
    }
    const std::string path = panel.URL.path.UTF8String;
    self->saved_paths_[captured_url] = path;
    self->CallFrontend("DevToolsAPI.savedURL(" + Quoted(captured_url) + ", " + Quoted(path) + ");");
  };
  // A sheet, never -runModal: a modal loop would starve BRWMessagePump.
  NSView* container = container_;
  if (container.window) {
    [panel beginSheetModalForWindow:container.window completionHandler:completion];
  } else {
    [panel beginWithCompletionHandler:completion];
  }
}

void BRWDevToolsHandler::Ack(int id, const std::string& json_argument) {
  if (id <= 0) {
    return;
  }
  CallFrontend("DevToolsAPI.embedderMessageAck(" + std::to_string(id) +
               (json_argument.empty() ? "" : ", " + json_argument) + ");");
}

void BRWDevToolsHandler::CallFrontend(const std::string& script) {
  if (!browser_) {
    return;
  }
  CefRefPtr<CefFrame> frame = browser_->GetMainFrame();
  if (frame) {
    frame->ExecuteJavaScript(script, "", 0);
  }
}

CefRefPtr<CefDictionaryValue> BRWDevToolsHandler::Preferences() {
  if (preferences_path_.empty()) {
    if (!private_preferences_) {
      private_preferences_ = CefDictionaryValue::Create();
    }
    return private_preferences_;
  }
  return LoadPreferences(preferences_path_);
}

void BRWDevToolsHandler::PreferencesChanged() {
  if (!preferences_path_.empty()) {
    SchedulePreferencesWrite(preferences_path_);
  }
}

