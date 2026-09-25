// Internal C++ interface, renderer process only -- never exposed to Swift.
//
// The renderer half of an embedded DevTools front-end (see
// BRWDevToolsHandler.h for the browser half). Chrome's own embedder gives the
// front-end a native `DevToolsHost` object and injects
// devtools_compatibility.js, which builds InspectorFrontendHost/DevToolsAPI on
// top of it. A plain Alloy browser gets neither, so this installs both, in
// the front-end's main frame, before any of the front-end's own scripts run.
#pragma once

#include <set>

#include "include/cef_browser.h"
#include "include/cef_frame.h"
#include "include/cef_v8.h"
#include "include/cef_values.h"

class BRWDevToolsFrontendRenderer {
 public:
  // Records `browser` as a bridge-created front-end when its extra_info
  // carries kBRWDevToolsFrontendExtraInfoKey.
  void OnBrowserCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDictionaryValue> extra_info);
  void OnBrowserDestroyed(CefRefPtr<CefBrowser> browser);

  // Installs DevToolsHost + devtools_compatibility.js when, and only when,
  // `browser` is a recorded front-end, `frame` is its main frame, and the
  // frame is showing the bundled front-end.
  void OnContextCreated(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefV8Context> context);

 private:
  std::set<int> frontend_browser_ids_;
};
