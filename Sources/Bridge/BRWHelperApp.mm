#import "BRWHelperApp.h"

#import "BRWPageMessageRouter.h"

BRWHelperApp::BRWHelperApp() {
  renderer_side_router_ = CefMessageRouterRendererSide::Create(BRWPageMessageRouter::Config());
}

void BRWHelperApp::OnBrowserCreated(CefRefPtr<CefBrowser> browser,
                                     CefRefPtr<CefDictionaryValue> extra_info) {
  devtools_frontend_.OnBrowserCreated(browser, extra_info);
}

void BRWHelperApp::OnBrowserDestroyed(CefRefPtr<CefBrowser> browser) {
  devtools_frontend_.OnBrowserDestroyed(browser);
}

void BRWHelperApp::OnContextCreated(CefRefPtr<CefBrowser> browser,
                                     CefRefPtr<CefFrame> frame,
                                     CefRefPtr<CefV8Context> context) {
  devtools_frontend_.OnContextCreated(browser, frame, context);
  renderer_side_router_->OnContextCreated(browser, frame, context);
}

void BRWHelperApp::OnContextReleased(CefRefPtr<CefBrowser> browser,
                                      CefRefPtr<CefFrame> frame,
                                      CefRefPtr<CefV8Context> context) {
  renderer_side_router_->OnContextReleased(browser, frame, context);
}

bool BRWHelperApp::OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                             CefRefPtr<CefFrame> frame,
                                             CefProcessId source_process,
                                             CefRefPtr<CefProcessMessage> message) {
  return renderer_side_router_->OnProcessMessageReceived(browser, frame, source_process, message);
}
