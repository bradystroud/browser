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
bool BRWContentBlockerShouldBlock(const std::string &profile_name, const std::string &host);
