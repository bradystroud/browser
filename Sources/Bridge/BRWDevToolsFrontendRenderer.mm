#import "BRWDevToolsFrontendRenderer.h"

#include <string>

#include "include/cef_process_message.h"

#import "BRWDevToolsShared.h"

namespace {

// Backs DevToolsHost.sendMessageToEmbedder: forwards one payload string to
// the browser process, from the frame that is calling it.
class EmbedderPostHandler : public CefV8Handler {
 public:
  bool Execute(const CefString& name,
               CefRefPtr<CefV8Value> object,
               const CefV8ValueList& arguments,
               CefRefPtr<CefV8Value>& retval,
               CefString& exception) override {
    if (arguments.size() != 1 || !arguments[0]->IsString()) {
      exception = "DevToolsHost: expected one string";
      return true;
    }
    CefRefPtr<CefV8Context> context = CefV8Context::GetCurrentContext();
    CefRefPtr<CefFrame> frame = context ? context->GetFrame() : nullptr;
    if (!frame || !frame->IsValid()) {
      return true;
    }
    CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(kBRWDevToolsEmbedderMessage);
    message->GetArgumentList()->SetString(0, arguments[0]->GetStringValue());
    frame->SendProcessMessage(PID_BROWSER, message);
    return true;
  }

 private:
  IMPLEMENT_REFCOUNTING(EmbedderPostHandler);
};

// Evaluates to a function taking the native post function and installing
// window.DevToolsHost -- the surface devtools_compatibility.js calls directly
// (the rest of the embedder API goes through sendMessageToEmbedder).
//
// isHostedMode() is false: that is what makes the front-end talk protocol
// through the embedder rather than stub itself out. Native context menus
// are never shown -- the browser side switches the front-end to its own
// in-page menus once it has loaded, and a right-click before then just
// gets no menu.
const char kHostBootstrap[] = R"JS(
(function (post) {
  'use strict';
  let zoom = 1;
  const host = {
    sendMessageToEmbedder(message) { post(String(message)); },
    platform() { return 'mac'; },
    isHostedMode() { return false; },
    zoomFactor() { return zoom; },
    _setZoomFactor(value) { zoom = Number(value) || 1; },
    copyText(text) {
      post(JSON.stringify({id: 0, method: 'copyText', params: [String(text)]}));
    },
    showContextMenuAtPoint() {
      setTimeout(() => window.DevToolsAPI && window.DevToolsAPI.contextMenuCleared(), 0);
    },
    isolatedFileSystem() { return null; },
    upgradeDraggedFileSystemPermissions() {},
  };
  Object.defineProperty(window, 'DevToolsHost', {value: Object.freeze(host)});
})
)JS";

// The version of devtools_compatibility.js that ships with this very
// front-end, read from the front-end's own origin rather than vendored, so
// the two can never drift apart across CEF updates. Synchronous on purpose:
// it has to be in place before the front-end's module scripts evaluate.
const char kLoadCompatibilityScript[] = R"JS(
(function () {
  try {
    const request = new XMLHttpRequest();
    request.open('GET', 'devtools://devtools/bundled/devtools_compatibility.js', false);
    request.send();
    return request.status === 200 ? request.responseText : '';
  } catch (e) {
    return '';
  }
})()
)JS";

bool IsFrontendURL(const std::string& url) {
  return url.rfind(kBRWDevToolsFrontendOrigin, 0) == 0;
}

void ReportFailure(CefRefPtr<CefV8Context> context, const std::string& what) {
  CefRefPtr<CefV8Value> ignored;
  CefRefPtr<CefV8Exception> exception;
  context->Eval("console.error('BRWDevTools: " + what + "')", "", 0, ignored, exception);
}

}  // namespace

void BRWDevToolsFrontendRenderer::OnBrowserCreated(CefRefPtr<CefBrowser> browser,
                                                   CefRefPtr<CefDictionaryValue> extra_info) {
  if (extra_info && extra_info->HasKey(kBRWDevToolsFrontendExtraInfoKey) &&
      extra_info->GetBool(kBRWDevToolsFrontendExtraInfoKey)) {
    frontend_browser_ids_.insert(browser->GetIdentifier());
  }
}

void BRWDevToolsFrontendRenderer::OnBrowserDestroyed(CefRefPtr<CefBrowser> browser) {
  frontend_browser_ids_.erase(browser->GetIdentifier());
}

void BRWDevToolsFrontendRenderer::OnContextCreated(CefRefPtr<CefBrowser> browser,
                                                   CefRefPtr<CefFrame> frame,
                                                   CefRefPtr<CefV8Context> context) {
  if (!frontend_browser_ids_.count(browser->GetIdentifier()) || !frame->IsMain() ||
      !IsFrontendURL(frame->GetURL().ToString())) {
    return;
  }

  CefRefPtr<CefV8Value> installer;
  CefRefPtr<CefV8Exception> exception;
  if (!context->Eval(kHostBootstrap, "", 0, installer, exception) || !installer ||
      !installer->IsFunction()) {
    ReportFailure(context, "DevToolsHost bootstrap failed");
    return;
  }
  CefV8ValueList args;
  args.push_back(CefV8Value::CreateFunction("sendMessageToEmbedder", new EmbedderPostHandler()));
  installer->ExecuteFunctionWithContext(context, nullptr, args);

  CefRefPtr<CefV8Value> source;
  if (!context->Eval(kLoadCompatibilityScript, "", 0, source, exception) || !source ||
      !source->IsString() || source->GetStringValue().empty()) {
    ReportFailure(context, "could not load devtools_compatibility.js");
    return;
  }
  CefRefPtr<CefV8Value> ignored;
  if (!context->Eval(source->GetStringValue(),
                     "devtools://devtools/bundled/devtools_compatibility.js", 1, ignored,
                     exception)) {
    ReportFailure(context, "devtools_compatibility.js threw");
  }
}
