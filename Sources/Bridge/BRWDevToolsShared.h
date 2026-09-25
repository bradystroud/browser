// Internal, header-only -- shared by the browser process (BRWDevToolsHandler)
// and the renderer (BRWDevToolsFrontendRenderer), which link different
// sources. Never exposed to Swift.
#pragma once

// The bundled Chrome DevTools front-end an embedded DevTools browser loads,
// which CEF serves under the devtools:// scheme itself.
//
// Deliberately without Chrome's can_dock=true. A docked front-end expects to
// cover the whole tab and lays out an empty "inspected page" area beside
// itself, for the embedder to position the page into; here the page and
// DevTools are separate views the app lays out. Undocked, it fills its
// view -- at the cost of the dock-side menu and the toolbar close button,
// which only exist docked.
inline constexpr char kBRWDevToolsFrontendURL[] = "devtools://devtools/bundled/devtools_app.html";
inline constexpr char kBRWDevToolsFrontendOrigin[] = "devtools://devtools/bundled/";

// Set in the extra_info of every front-end browser the bridge creates, and
// only those. The renderer keys the embedder shim on the browser this marks,
// never on a URL: a tab that navigates to devtools:// must not get it.
inline constexpr char kBRWDevToolsFrontendExtraInfoKey[] = "brw_devtools_frontend";

// Renderer -> browser: one DevToolsHost.sendMessageToEmbedder() payload, the
// JSON string {id, method, params} devtools_compatibility.js builds.
inline constexpr char kBRWDevToolsEmbedderMessage[] = "BRWDevTools.embedder";
