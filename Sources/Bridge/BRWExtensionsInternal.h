// Internal C++ interface for the extension runtime -- never exposed to Swift.
// The public side is BRWExtensions.h.
#pragma once

#include <string>

#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_request_context.h"
#include "include/cef_request_context_handler.h"
#include "include/cef_resource_request_handler.h"

/// Adds the folders given to +[BRWExtensionRuntime setLoadExtensionPaths:]
/// to `command_line`'s `load-extension` switch, after any value already on
/// it. Browser process only; BRWCefApp::OnBeforeCommandLineProcessing is the
/// one caller.
void BRWExtensionsAppendLoadExtensionSwitch(CefRefPtr<CefCommandLine> command_line);

/// The handler for a request to the reserved bridge host, or nullptr for any
/// other request. Callable on the IO thread. `profile_id` is the profile
/// whose context made the request, and empty for a context that must never
/// get the channel (a private window's, or one no profile owns): such a
/// request is answered with an error. Either way, a non-null return has set
/// `disable_default_handling`, so the request never reaches the network.
///
/// Both request paths call this: a request with a browser reaches
/// BRWClientHandler::GetResourceRequestHandler, and one without (an
/// extension's service worker) reaches the context's own handler from
/// BRWCreateExtensionContextHandler. CEF consults the context's handler only
/// when the client's returned nullptr, so each path must check for itself.
CefRefPtr<CefResourceRequestHandler> BRWExtensionBridgeHandlerForRequest(
    const std::string& profile_id,
    CefRefPtr<CefRequest> request,
    const CefString& request_initiator,
    bool& disable_default_handling);

/// Whether `url` is on the bridge's reserved host. Any thread.
bool BRWIsExtensionBridgeURL(const CefString& url);

/// Where a redirect into the bridge host is sent instead: a bridge URL the
/// bridge always refuses, as if the host did not resolve. A redirect lets the
/// server that was fetched choose the bridge request, so none may arrive.
std::string BRWExtensionBridgeRedirectRefusedURL();

/// Registers the bridge host's scheme handler factory on `context`. The
/// context handler from BRWCreateExtensionContextHandler does this itself in
/// OnRequestContextInitialized; see BridgeSchemeHandlerFactory for why the
/// handler alone does not cover an extension's service worker.
void BRWRegisterExtensionBridgeSchemeHandler(CefRefPtr<CefRequestContext> context, const std::string& profile_id);

/// The CefRequestContextHandler to create a context with. `profile_id` empty
/// means a context with no channel; see BRWExtensionBridgeHandlerForRequest.
CefRefPtr<CefRequestContextHandler> BRWCreateExtensionContextHandler(const std::string& profile_id);

/// The client BRWCefApp::GetDefaultClient returns: it takes every Chrome-style
/// browser Chromium creates on its own, cancels its navigation, closes it and
/// reports it to the delegate. See BRWExtensions.mm.
CefRefPtr<CefClient> BRWUnmanagedBrowserClient();

/// Unmanaged browsers not yet through OnBeforeClose. +[BRWEngine
/// requestShutdownWithCompletion:] waits for this to reach zero, with
/// BRWClientHandler::LiveCount, before CefShutdown.
size_t BRWUnmanagedBrowserLiveCount();

/// Asks every unmanaged browser still open to close. Part of shutdown.
void BRWCloseUnmanagedBrowsers();

/// True while the activation guard runs: from an unmanaged browser's creation
/// until a second after the last one closed, at most 3 s per browser and 5 s
/// in any 60 s (see ExtendActivationGuard). -[BRWApplication
/// activateIgnoringOtherApps:] and -activate do nothing then: Chromium activates the app when it shows its own window,
/// which would take the user's keyboard from whatever app they are in. Main
/// thread only.
bool BRWExtensionsShouldSuppressActivation();

/// BRWCefApp::OnContextInitialized: the global context and Chromium's
/// initial profile have loaded. See +[BRWExtensionRuntime engineContextInitialized].
void BRWExtensionsNoteEngineContextInitialized();
