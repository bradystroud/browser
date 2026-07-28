// Internal C++ interface shared between BRWThreatList.mm and
// BRWClientHandler.mm -- never exposed to Swift (unlike BRWThreatList.h,
// which is).
#pragma once

#include <string>

/// True if a request to `host` (top-level or subresource, from a browser
/// belonging to `profile_name`) should be treated as a known threat --
/// combines the shared threat-domain list, that profile's "warn about
/// dangerous sites" setting, and any session-scoped bypass already granted
/// for this exact (profile_name, host) pair via "Continue anyway". Safe to
/// call from any thread; in practice only ever called from CEF's IO thread
/// (BRWClientHandler::OnBeforeResourceLoad, its only caller) -- see
/// BRWThreatList.mm's class-level comment for why neither the snapshot nor
/// the bypass set needs a lock given that.
///
/// Fails open (returns false) if no snapshot has been published yet, if
/// `profile_name` has no known settings, or if `host` is empty -- same
/// fail-open convention as BRWContentBlockerShouldBlock.
bool BRWThreatListShouldWarn(const std::string &profile_name, const std::string &host);

/// Records that the user clicked "Continue anyway" for `host` in
/// `profile_name` -- BRWThreatListShouldWarn returns false for this exact
/// (profile_name, host) pair (and its subdomains, same semantics as
/// DomainTrie/the ad-blocker's allowlist) for the rest of this process's
/// run. Never persisted to disk, and forgotten entirely on relaunch --
/// "session-scoped" per browser-12m.6.
void BRWThreatListAddSessionBypass(const std::string &profile_name, const std::string &host);

/// True if `url` is this app's own "Continue anyway" marker link (see
/// BlockListCore's ThreatWarningLink.swift for the matching Swift-side
/// encoder used when building the interstitial page's link, and for why
/// the exact host/path/query-key literals are kept in sync by convention
/// rather than a shared header) -- if so, `*out_original_url` is set to the
/// real URL it was guarding.
bool BRWThreatListParseContinueMarker(const std::string &url, std::string *out_original_url);

/// Builds the interstitial page to show for a blocked top-level navigation
/// to `host` (the original, now-cancelled navigation was to
/// `original_url`) -- delegates to the Swift-provided builder registered
/// via +[BRWThreatList setInterstitialPageBuilder:]. MUST be called from
/// the UI thread (== this app's main thread, see BRWBrowser.h's own note on
/// that) -- the registered block is Swift code, same thread-affinity
/// requirement as every other Swift-reaching bridge callback. Returns an
/// empty string if nothing is registered yet (should not happen in
/// practice -- ThreatListCoordinator registers it before the engine
/// finishes initializing, and before any browser can navigate).
std::string BRWThreatListBuildInterstitialURL(const std::string &host, const std::string &original_url);
