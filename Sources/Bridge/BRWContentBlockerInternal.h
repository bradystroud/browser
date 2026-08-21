// Internal C++ interface shared between BRWContentBlocker.mm and
// BRWClientHandler.mm -- never exposed to Swift (unlike BRWContentBlocker.h,
// which is).
#pragma once

#include <string>

/// True if a request to `host` (from a browser tab belonging to
/// `profile_name`) should be blocked, per the most recently published
/// content-blocker snapshot (see BRWContentBlocker.mm's class-level comment
/// for the full atomic-swap threading model this reads from). Safe to call
/// from any thread, including CEF's IO thread -- reads a single atomically
/// published pointer with no locking on this, the hot path.
///
/// Fails open (returns false) if no snapshot has been published yet (e.g.
/// called before the app's launch-time load completes), if `profile_name`
/// has no known settings, or if `host` is empty -- silently failing to
/// block an ad is a much smaller problem than silently breaking page loads.
///
/// When non-null and the answer is true, `matched_domain` receives the BLOCK
/// LIST ENTRY that matched rather than `host` itself -- the list matches a
/// domain and every subdomain beneath it, so a request to
/// "stats.g.doubleclick.net" reports "doubleclick.net". That is what the
/// privacy report (browser-e7r) names as the tracker: without it, one
/// tracker's subdomains would be listed as if they were separate trackers,
/// which inflates the only number in that report a user actually reads.
bool BRWContentBlockerShouldBlock(const std::string &profile_name,
                                  const std::string &host,
                                  std::string *matched_domain = nullptr);
