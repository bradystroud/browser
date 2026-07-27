// Internal C++ interface shared between BRWEngine.mm and BRWBrowser.mm --
// never exposed to Swift (unlike BRWEngine.h/BRWBrowser.h, which are).
#pragma once

#include <string>

#include "include/cef_request_context.h"

/// Returns the shared CefRequestContext for `profile_name`, creating one
/// (with cache_path under BRWEngine's root_cache_path, set by
/// +[BRWEngine initializeWithProfilesRootPath:]) if this is the first
/// request for that profile -- see BRWEngine.mm's ProfileContexts() for why
/// this is shared rather than per-BRWBrowser.
CefRefPtr<CefRequestContext> BRWGetOrCreateProfileContext(const std::string &profile_name);
