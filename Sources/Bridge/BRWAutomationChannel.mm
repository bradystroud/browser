#import "BRWAutomationChannel.h"

#include "include/cef_parser.h"
#include "include/wrapper/cef_helpers.h"

namespace {
// Below BRWDevToolsHandler's kFrontendIdOffset (1000000000), which it treats
// as the front-end's own, and far above anything CEF numbers by itself for
// responsive design mode. Global, not per channel: one counter can never hand
// two channels on the same browser the same id.
constexpr int kAutomationIdBase = 900000000;
int g_next_automation_id = 0;

NSString* ToNSString(const void* data, size_t size) {
  if (!data || size == 0) {
    return @"{}";
  }
  return [[NSString alloc] initWithBytes:data length:size encoding:NSUTF8StringEncoding] ?: @"{}";
}

NSString* ErrorJSON(NSString* message) {
  NSData* data = [NSJSONSerialization dataWithJSONObject:@{@"message" : message} options:0 error:nil];
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}
}  // namespace

void BRWAutomationChannel::Execute(CefRefPtr<CefBrowser> browser,
                                   const std::string& method,
                                   const std::string& params_json,
                                   Completion completion) {
  CEF_REQUIRE_UI_THREAD();
  Completion block = [completion copy];
  if (!browser) {
    dispatch_async(dispatch_get_main_queue(), ^{
      block(NO, ErrorJSON(@"the page has no live browser yet"));
    });
    return;
  }
  if (!registration_ || registered_browser_id_ != browser->GetIdentifier()) {
    registration_ = browser->GetHost()->AddDevToolsMessageObserver(this);
    registered_browser_id_ = browser->GetIdentifier();
  }

  CefRefPtr<CefDictionaryValue> params;
  if (!params_json.empty()) {
    CefRefPtr<CefValue> parsed = CefParseJSON(params_json, JSON_PARSER_RFC);
    if (!parsed || parsed->GetType() != VTYPE_DICTIONARY) {
      dispatch_async(dispatch_get_main_queue(), ^{
        block(NO, ErrorJSON(@"params must be a JSON object"));
      });
      return;
    }
    params = parsed->GetDictionary();
  }

  g_next_automation_id = (g_next_automation_id + 1) % 90000000;
  const int id = kAutomationIdBase + g_next_automation_id;
  if (browser->GetHost()->ExecuteDevToolsMethod(id, method, params) == 0) {
    dispatch_async(dispatch_get_main_queue(), ^{
      block(NO, ErrorJSON(@"the engine refused the command"));
    });
    return;
  }
  // Results arrive asynchronously on this same thread, so storing the
  // completion after the call cannot miss one.
  pending_[id] = block;
}

void BRWAutomationChannel::SetEventHandler(EventHandler handler) {
  event_handler_ = [handler copy];
}

void BRWAutomationChannel::Close() {
  registration_ = nullptr;
  registered_browser_id_ = 0;
  event_handler_ = nil;
  FailAll(@"the page closed");
}

void BRWAutomationChannel::OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser,
                                                  int message_id,
                                                  bool success,
                                                  const void* result,
                                                  size_t result_size) {
  auto it = pending_.find(message_id);
  if (it == pending_.end()) {
    return;
  }
  Completion block = it->second;
  pending_.erase(it);
  NSString* json = ToNSString(result, result_size);
  dispatch_async(dispatch_get_main_queue(), ^{
    block(success ? YES : NO, json);
  });
}

void BRWAutomationChannel::OnDevToolsEvent(CefRefPtr<CefBrowser> browser,
                                           const CefString& method,
                                           const void* params,
                                           size_t params_size) {
  if (!event_handler_) {
    return;
  }
  EventHandler handler = event_handler_;
  NSString* name = [NSString stringWithUTF8String:method.ToString().c_str()];
  NSString* json = ToNSString(params, params_size);
  dispatch_async(dispatch_get_main_queue(), ^{
    handler(name, json);
  });
}

void BRWAutomationChannel::OnDevToolsAgentDetached(CefRefPtr<CefBrowser> browser) {
  // CEF never delivers results that were pending across a detach.
  FailAll(@"the page's DevTools agent detached");
}

void BRWAutomationChannel::FailAll(NSString* reason) {
  if (pending_.empty()) {
    return;
  }
  std::map<int, Completion> failed;
  failed.swap(pending_);
  NSString* json = ErrorJSON(reason);
  dispatch_async(dispatch_get_main_queue(), ^{
    for (auto& entry : failed) {
      entry.second(NO, json);
    }
  });
}
