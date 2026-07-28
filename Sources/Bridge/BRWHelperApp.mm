#import "BRWHelperApp.h"

#import "BRWPageMessageRouter.h"

BRWHelperApp::BRWHelperApp() {
  renderer_side_router_ = CefMessageRouterRendererSide::Create(BRWPageMessageRouter::Config());
}

void BRWHelperApp::OnContextCreated(CefRefPtr<CefBrowser> browser,
                                     CefRefPtr<CefFrame> frame,
                                     CefRefPtr<CefV8Context> context) {
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
