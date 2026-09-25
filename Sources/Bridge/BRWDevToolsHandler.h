// Internal C++ interface -- never exposed to Swift.
//
// One tab's Chromium DevTools, plus the static entry points BRWBrowser and
// BRWClientHandler use to open, move and close it. Two placements:
//
// - Separate window (nil container): CefBrowserHost::ShowDevTools, i.e.
//   CEF's own top-level DevTools window.
//
// - Embedded (a container NSView): CEF cannot do this itself. ShowDevTools
//   only builds Chrome-style DevTools browsers (an Alloy-style one trips a
//   CHECK in browser_host_create.cc and takes the app down), and on macOS a
//   parent view forces Alloy style. So this is a self-hosted front-end
//   instead: an ordinary Alloy child browser of the container, loading the
//   bundled front-end (kBRWDevToolsFrontendURL), with this class playing the
//   part of Chrome's DevToolsUIBindings. The renderer side
//   (BRWDevToolsFrontendRenderer) gives it the DevToolsHost object and
//   devtools_compatibility.js Chrome's embedder would; the protocol travels
//   over the inspected browser's own CefBrowserHost::SendDevToolsMessage /
//   AddDevToolsMessageObserver session, so a front-end can only ever reach
//   the one tab it was opened for, never another tab or the browser target.
//
// The inspected browser's own CefRequestContext hosts the front-end browser
// too, and DevTools settings persist in <profile dir>/devtools-preferences.json
// (in memory only for a private window).
#pragma once

#import <AppKit/AppKit.h>

#include <map>
#include <set>
#include <string>

#include "include/cef_client.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_display_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_registration.h"
#include "include/cef_request_handler.h"
#include "include/cef_values.h"

#import "BRWBrowser.h"  // for BRWDevToolsPanel.

class BRWClientHandler;

class BRWDevToolsHandler : public CefClient,
                           public CefLifeSpanHandler,
                           public CefLoadHandler,
                           public CefDisplayHandler,
                           public CefRequestHandler,
                           public CefDevToolsMessageObserver {
 public:
  struct Request {
    // nil means CEF's own separate DevTools window.
    __weak NSView* container = nil;
    BRWDevToolsPanel panel = BRWDevToolsPanelDefault;
    bool has_point = false;
    // CEF view coordinates of the inspected browser: DIP, top-left origin.
    int x = 0;
    int y = 0;
    bool start_picker = false;
  };

  // Opens (or focuses, moves, or re-targets) `owner`'s DevTools. A no-op when
  // `owner` has no live browser or is already closing.
  static void Show(BRWClientHandler* owner, const Request& request);

  // Closes `owner`'s DevTools, if any. Safe to call repeatedly.
  static void Close(BRWClientHandler* owner);

  // Whether `owner` has DevTools open, or opening, and not being closed.
  static bool IsOpen(BRWClientHandler* owner);

  // Every DevTools browser not yet OnBeforeClose'd -- counted into
  // BRWClientHandler::LiveCount(), because CefShutdown needs these gone too.
  static size_t LiveCount();
  static void CloseAll();

  ~BRWDevToolsHandler() override;

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  // CefClient methods:
  // Embedder messages from the front-end's DevToolsHost. Accepted only from
  // this handler's own embedded front-end browser, its main frame, showing
  // the bundled front-end.
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override;

  // CefLifeSpanHandler methods:
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  // An embedded front-end's view is taken out of the window here, for the
  // same reason BRWClientHandler::RequestClose does it for a page: CEF's
  // default close for a SetAsChild browser sends -performClose: to the view's
  // NSWindow, which would close the whole browser window, and it is the
  // view's teardown that delivers OnBeforeClose.
  bool DoClose(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;
  // Links DevTools opens go to the inspected tab's delegate as new tabs,
  // never a raw CEF window.
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
                     bool* no_javascript_access) override;

  // CefLoadHandler methods:
  void OnLoadStart(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   TransitionType transition_type) override;

  // CefDisplayHandler methods:
  bool OnConsoleMessage(CefRefPtr<CefBrowser> browser,
                        cef_log_severity_t level,
                        const CefString& message,
                        const CefString& source,
                        int line) override;

  // CefRequestHandler methods:
  // The embedded front-end's main frame may only ever show the bundled
  // front-end; anything else it tries to navigate to is refused (and, for a
  // web URL, opened as a tab instead).
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                      CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request,
                      bool user_gesture,
                      bool is_redirect) override;
  bool OnOpenURLFromTab(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        const CefString& target_url,
                        WindowOpenDisposition target_disposition,
                        bool user_gesture) override;
  // A crashed front-end is closed rather than left as a dead pane.
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                 TerminationStatus status,
                                 int error_code,
                                 const CefString& error_string) override;

  // CefDevToolsMessageObserver methods (the inspected browser's session):
  bool OnDevToolsMessage(CefRefPtr<CefBrowser> browser,
                         const void* message,
                         size_t message_size) override;

 private:
  BRWDevToolsHandler(BRWClientHandler* owner, NSView* container);

  void AttachViewToContainer();
  void MoveTo(NSView* container);
  void RequestClose();

  // Front-end actions (panel switch, element picker, inspect-at-point), held
  // until the front-end reports loadCompleted.
  void QueueAction(const Request& request);
  void FlushActions();
  void InspectAt(int x, int y, int attempt);

  // Embedder protocol (see devtools_compatibility.js).
  void HandleEmbedderMessage(const std::string& json);
  void DispatchProtocolMessageFromFrontend(const std::string& message);
  void SendBridgeCommand(int id, const std::string& method, CefRefPtr<CefDictionaryValue> params);
  void ResetInspectedPageState();
  void Save(const std::string& url, const std::string& content, bool force_save_as, bool is_base64);
  void Ack(int id, const std::string& json_argument);
  void CallFrontend(const std::string& script);
  CefRefPtr<CefDictionaryValue> Preferences();
  void PreferencesChanged();

  CefRefPtr<BRWClientHandler> owner_;
  bool embedded_ = false;
  __weak NSView* container_ = nil;
  CefRefPtr<CefBrowser> browser_;
  CefRefPtr<CefRegistration> observer_registration_;
  bool frontend_ready_ = false;
  bool pending_close_ = false;
  bool close_requested_ = false;
  bool closed_ = false;

  // Actions waiting for loadCompleted.
  std::string pending_panel_;
  bool pending_picker_ = false;
  bool pending_inspect_ = false;
  int pending_inspect_x_ = 0;
  int pending_inspect_y_ = 0;

  // Protocol domains the front-end enabled on the inspected browser's
  // session (root session only), and whether it touched state that outlives
  // a domain being disabled -- see ResetInspectedPageState.
  std::set<std::string> enabled_domains_;
  bool used_device_emulation_ = false;
  bool used_cpu_throttling_ = false;
  bool used_network_conditions_ = false;
  int next_bridge_id_ = 0;
  std::map<int, std::pair<int, int>> inspect_requests_;  // bridge id -> (x, y)
  std::map<int, int> inspect_attempts_;

  // <profile dir>/devtools-preferences.json, or empty for a private window,
  // whose preferences live in private_preferences_ for this instance only.
  std::string preferences_path_;
  CefRefPtr<CefDictionaryValue> private_preferences_;
  std::map<std::string, std::string> saved_paths_;  // front-end URL -> file

  // A Show() that arrived while this instance was closing, or that needs a
  // different placement (window <-> embedded) than this instance has. Replayed
  // against the owner once this instance's OnBeforeClose has run.
  bool has_reopen_ = false;
  Request reopen_;

  IMPLEMENT_REFCOUNTING(BRWDevToolsHandler);
};
