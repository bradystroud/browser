#import "BRWThreatList.h"
#import "BRWStringUtil.h"
#import "BRWThreatListInternal.h"

#include <atomic>
#include <memory>
#include <string>
#include <unordered_map>
#include <unordered_set>

#include "include/cef_parser.h"

// Threading model: the (domains, profile-settings) snapshot uses the exact
// same atomic-swap-raw-pointer pattern as BRWContentBlocker.mm -- see that
// file's class-level comment for the full reasoning (std::atomic<shared_ptr>
// unavailable on this toolchain's libc++, snapshots deliberately leaked
// since reclaiming one safely needs a real epoch/hazard-pointer scheme that
// updates this infrequent don't warrant); not re-derived here.
//
// The session bypass set is simpler and needs no lock at all: both of its
// callers (BRWThreatListShouldWarn, BRWThreatListAddSessionBypass) are only
// ever invoked from BRWClientHandler::OnBeforeResourceLoad, and CEF's IO
// thread is one single OS thread process-wide (not a pool) -- every call
// into this file's IO-thread-only state is already serialized by CEF
// itself before it ever reaches here.
//
// The registered interstitial-page-builder block is main-thread-set-once
// (ThreatListCoordinator.start(), before any browser can navigate),
// UI-thread-read thereafter -- and CEF's UI thread *is* this app's main
// thread (external message pump, single-threaded, see BRWBrowser.h's own
// note on that), so no lock is needed there either.
namespace {

struct ProfileThreatSettings {
  bool enabled = true;
};

// Immutable once constructed -- see this file's top-of-file comment.
struct ThreatSnapshot {
  std::unordered_set<std::string> threat_domains;
  std::unordered_map<std::string, ProfileThreatSettings> profile_settings;
};

std::atomic<const ThreatSnapshot *> g_snapshot{nullptr};

// IO-thread-only -- see this file's top-of-file comment.
std::unordered_map<std::string, std::unordered_set<std::string>> &SessionBypasses() {
  static std::unordered_map<std::string, std::unordered_set<std::string>> bypasses;
  return bypasses;
}

// Main-thread-set-once, UI-thread-read (same thread in this app) -- mirrors
// BRWEngine.mm's WindowCloseHandler() pattern exactly.
using InterstitialBuilderBlock = NSString * _Nullable (^)(NSString *host, NSString *originalURL);
InterstitialBuilderBlock __strong &InterstitialBuilder() {
  static InterstitialBuilderBlock builder = nil;
  return builder;
}

// This app's own "Continue anyway" marker link -- an IANA-reserved
// .invalid host (RFC 2606) that never resolves and is always intercepted
// right here before CEF would otherwise try to look it up. Kept in sync by
// convention (not a shared header -- Swift and C++ don't share one) with
// BlockListCore's ThreatWarningLink.swift, the only place this link is
// ever generated.
const char kContinueMarkerPrefix[] =
    "https://browser-safety-warning.invalid/continue-unsafe?url=";

}  // namespace

bool BRWThreatListShouldWarn(const std::string &profile_name, const std::string &host) {
  if (host.empty()) {
    return false;
  }

  auto bypass_it = SessionBypasses().find(profile_name);
  if (bypass_it != SessionBypasses().end() && IsHostOrAncestorInSet(host, bypass_it->second)) {
    return false;  // Bypassed always wins, same precedence as the ad-blocker's allowlist.
  }

  const ThreatSnapshot *snapshot = g_snapshot.load(std::memory_order_acquire);
  if (!snapshot) {
    return false;
  }
  auto profile_it = snapshot->profile_settings.find(profile_name);
  if (profile_it == snapshot->profile_settings.end() || !profile_it->second.enabled) {
    return false;
  }
  return IsHostOrAncestorInSet(host, snapshot->threat_domains);
}

void BRWThreatListAddSessionBypass(const std::string &profile_name, const std::string &host) {
  if (host.empty()) {
    return;
  }
  SessionBypasses()[profile_name].insert(ToLowerASCII(host));
}

bool BRWThreatListParseContinueMarker(const std::string &url, std::string *out_original_url) {
  // A hand-rolled, deliberately narrow parse -- this only ever needs to
  // recognize a URL *we* generated (see ThreatWarningLink.swift), never an
  // arbitrary attacker-controlled one. A page can link to this exact
  // host/path itself, but that only ever "bypasses" a threat finding for
  // whatever *it* put in `url=` -- there's no way to use this marker to
  // bypass the warning for a different, unrelated site than the one
  // already embedded in the link.
  if (url.rfind(kContinueMarkerPrefix, 0) != 0) {
    return false;
  }
  const std::string encoded = url.substr(sizeof(kContinueMarkerPrefix) - 1);
  // CefURIDecode reverses Swift's CharacterSet.urlQueryAllowed percent-
  // encoding (ThreatWarningLink.continueURL(bypassing:)) -- UU_SPACES and
  // UU_URL_SPECIAL_CHARS_EXCEPT_PATH_SEPARATORS together unescape every
  // character that encoding could have produced ('%', '+', '&', '#',
  // spaces), and convert_to_utf8=true handles a non-ASCII original URL
  // (e.g. an IDN host) correctly.
  const CefString decoded = CefURIDecode(
      encoded, /*convert_to_utf8=*/true,
      static_cast<cef_uri_unescape_rule_t>(UU_SPACES | UU_URL_SPECIAL_CHARS_EXCEPT_PATH_SEPARATORS));
  if (out_original_url) {
    *out_original_url = decoded.ToString();
  }
  return true;
}

std::string BRWThreatListBuildInterstitialURL(const std::string &host, const std::string &original_url) {
  InterstitialBuilderBlock builder = InterstitialBuilder();
  if (!builder) {
    return std::string();
  }
  NSString *result = builder([NSString stringWithUTF8String:host.c_str()],
                              [NSString stringWithUTF8String:original_url.c_str()]);
  return result ? ToStdString(result) : std::string();
}

@implementation BRWProfileThreatSettings {
 @public
  BOOL _enabled;
}

- (instancetype)initWithEnabled:(BOOL)enabled {
  self = [super init];
  if (self) {
    _enabled = enabled;
  }
  return self;
}

@end

@implementation BRWThreatList

+ (void)updateWithThreatDomains:(NSArray<NSString *> *)threatDomains
                  profileSettings:(NSDictionary<NSString *, BRWProfileThreatSettings *> *)profileSettings {
  auto snapshot = std::make_unique<ThreatSnapshot>();

  snapshot->threat_domains.reserve(threatDomains.count);
  for (NSString *domain in threatDomains) {
    snapshot->threat_domains.insert(ToLowerASCII(ToStdString(domain)));
  }

  for (NSString *profileName in profileSettings) {
    BRWProfileThreatSettings *settings = profileSettings[profileName];
    ProfileThreatSettings cppSettings;
    cppSettings.enabled = settings->_enabled;
    snapshot->profile_settings[ToStdString(profileName)] = cppSettings;
  }

  // Deliberately leaked -- see this file's top-of-file comment.
  g_snapshot.store(snapshot.release(), std::memory_order_release);
}

+ (void)setInterstitialPageBuilder:(NSString * (^)(NSString *host, NSString *originalURL))builder {
  InterstitialBuilder() = [builder copy];
}

@end
