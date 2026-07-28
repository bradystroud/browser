#import "BRWPageMessageRouter.h"

#include <map>

#import "BRWClientHandler.h"

namespace {
NSString* ToNSString(const CefString& s) {
  return [NSString stringWithUTF8String:s.ToString().c_str()];
}
}  // namespace

// Implements CefMessageRouterBrowserSide::Handler. Not CefBaseRefCounted --
// Handler is a plain interface class per its own header -- so this is owned
// directly by BRWPageMessageRouter (a process-wide singleton with static
// storage duration) via std::unique_ptr, matching Handler's own documented
// lifetime contract ("must either outlive the router or be removed before
// deletion").
class BRWPageMessageRouter::HandlerImpl : public CefMessageRouterBrowserSide::Handler {
 public:
  bool OnQuery(CefRefPtr<CefBrowser> browser,
               CefRefPtr<CefFrame> frame,
               int64_t query_id,
               const CefString& request,
               bool persistent,
               CefRefPtr<Callback> callback) override {
    BRWClientHandler* handler = BRWClientHandler::ForBrowser(browser);
    id<BRWBrowserDelegate> delegate = handler ? handler->GetDelegate() : nil;
    if (!delegate || ![delegate respondsToSelector:@selector(browserDidReceivePageMessage:requestId:)]) {
      return false;  // Not handled -- CEF auto-cancels with error -1.
    }
    pending_[query_id] = callback;
    [delegate browserDidReceivePageMessage:ToNSString(request) requestId:query_id];
    return true;
  }

  void OnQueryCanceled(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int64_t query_id) override {
    pending_.erase(query_id);
  }

  void Respond(int64_t requestId, bool success, const std::string& response) {
    auto it = pending_.find(requestId);
    if (it == pending_.end()) {
      return;
    }
    CefRefPtr<Callback> callback = it->second;
    pending_.erase(it);
    if (success) {
      callback->Success(response);
    } else {
      callback->Failure(0, response);
    }
  }

 private:
  std::map<int64_t, CefRefPtr<Callback>> pending_;
};

// static
BRWPageMessageRouter& BRWPageMessageRouter::Get() {
  // Deliberately leaked (never destructed), unlike BRWClientHandler's own
  // Registry(), which only holds raw pointers: this object owns a real
  // CefRefPtr<CefMessageRouterBrowserSide>, and a normal function-local
  // static's destructor would run at process exit via the C++ runtime's
  // atexit machinery -- which is *after* +[BRWEngine shutdown]'s explicit
  // CefShutdown() call earlier in the same quit sequence (see
  // docs/ai-tasks/quit-crash-notes.md), by which point releasing a
  // CefRefPtr touches already-torn-down CEF internals. A leaked raw pointer
  // is never destructed at all, sidestepping that ordering hazard entirely.
  static BRWPageMessageRouter* instance = new BRWPageMessageRouter();
  return *instance;
}

BRWPageMessageRouter::BRWPageMessageRouter() {
  router_ = CefMessageRouterBrowserSide::Create(Config());
  handler_ = std::make_unique<HandlerImpl>();
  router_->AddHandler(handler_.get(), /*first=*/false);
}

void BRWPageMessageRouter::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  router_->OnBeforeClose(browser);
}

void BRWPageMessageRouter::OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame) {
  router_->OnBeforeBrowse(browser, frame);
}

void BRWPageMessageRouter::OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser) {
  router_->OnRenderProcessTerminated(browser);
}

bool BRWPageMessageRouter::OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                                     CefRefPtr<CefFrame> frame,
                                                     CefProcessId source_process,
                                                     CefRefPtr<CefProcessMessage> message) {
  return router_->OnProcessMessageReceived(browser, frame, source_process, message);
}

void BRWPageMessageRouter::Respond(int64_t requestId, bool success, const std::string& response) {
  handler_->Respond(requestId, success, response);
}
