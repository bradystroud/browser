// Internal C++ interface shared between BRWEngine.mm and BRWBrowser.mm --
// never exposed to Swift (unlike BRWEngine.h/BRWBrowser.h, which are).
#pragma once

#include <string>

#include "include/cef_request_context.h"

/// Returns the shared CefRequestContext for `profile_id` (the profile's
/// stable UUID, not its mutable display name -- browser-ojw), creating one
/// (with cache_path under BRWEngine's root_cache_path, set by
/// +[BRWEngine initializeWithProfilesRootPath:]) if this is the first
/// request for that profile -- see BRWEngine.mm's ProfileContexts() for why
/// this is shared rather than per-BRWBrowser. Keying by id rather than name
/// means renaming a profile (see ProfileManager.updateProfile) never needs
/// to move this directory or leave an already-open window pointing at a
/// stale context.
CefRefPtr<CefRequestContext> BRWGetOrCreateProfileContext(const std::string &profile_id);

/// Creates a brand-new, never-cached, never-reused CefRequestContext with an
/// empty cache_path -- CEF's documented "incognito mode" (see
/// CefRequestContextSettings.cache_path's doc comment in
/// include/internal/cef_types.h): in-memory caches only, no profile-specific
/// data persisted to disk (installation-specific data still lands in
/// root_cache_path, which is unavoidable and unrelated to any one profile).
/// Used for Private Browsing (browser-12m.1) -- one dedicated ephemeral
/// context per private window, discarded (nothing to clean up; CEF frees it
/// once the last CefBrowser/reference using it is gone) once that window
/// closes. Never stored in BRWEngine.mm's ProfileContexts() map -- there is
/// deliberately no profile identity for a private window to look this back
/// up by.
CefRefPtr<CefRequestContext> BRWCreateEphemeralRequestContext();
