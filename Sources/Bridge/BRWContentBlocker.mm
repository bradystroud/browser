#import "BRWContentBlocker.h"
#import "BRWContentBlockerInternal.h"

#include <atomic>
#include <memory>
#include <string>
#include <unordered_map>
#include <unordered_set>

// Threading model (browser-12m.5.1): BRWClientHandler::OnBeforeResourceLoad
// runs on CEF's IO thread and needs a per-request blocking decision cheaply
// -- no locks on that hot path if avoidable. Settings/list updates only
// ever happen on the main thread (app launch, or a Settings window edit),
// are infrequent, and each update replaces the *entire* snapshot rather
// than mutating one in place, so a reader on the IO thread always sees a
// fully-built, internally-consistent BlockerSnapshot -- either the one
// from before the update or the one from after, never something
// half-written.
//
// This is implemented as a single atomically-swapped raw pointer
// (std::atomic<const BlockerSnapshot*>), not std::atomic<std::shared_ptr<T>>
// -- confirmed empirically that this toolchain's libc++ does not implement
// C++20's std::atomic<shared_ptr> specialization (it requires
// is_trivially_copyable, which shared_ptr's non-trivial ref-counted
// destructor/copy/move violates). A pointer-sized std::atomic is always
// lock-free on arm64/x86-64, which is what actually matters here. Every
// published snapshot is deliberately *never freed*: reclaiming one safely,
// while a concurrent IO-thread reader might still be mid-read on it, needs
// a real epoch/hazard-pointer scheme -- overkill for updates this
// infrequent and snapshots this small (bounded by the block list's size,
// at most a few MB). Intentionally leaking instead is the simplest correct
// choice.
namespace {

std::string ToStdString(NSString *s) {
  return s ? std::string([s UTF8String]) : std::string();
}

std::string ToLowerASCII(std::string s) {
  for (char &c : s) {
    if (c >= 'A' && c <= 'Z') {
      c = static_cast<char>(c - 'A' + 'a');
    }
  }
  return s;
}

struct ProfileBlockingSettings {
  bool enabled = true;
  std::unordered_set<std::string> allowlisted_hosts;
};

// Immutable once constructed -- see this file's top-of-file comment for the
// full threading model.
struct BlockerSnapshot {
  std::unordered_set<std::string> blocked_domains;
  std::unordered_map<std::string, ProfileBlockingSettings> profile_settings;
};

std::atomic<const BlockerSnapshot *> g_snapshot{nullptr};

// Mirrors BlockListCore's DomainTrie.contains(host:) semantics exactly: a
// domain in `domains` blocks/allows itself and every subdomain of it, but
// never its own parent. Walks from the full host up through each ancestor
// domain (dropping one leftmost label at a time) down to the bare TLD,
// returning true as soon as any level is found in the set.
bool IsHostOrAncestorInSet(const std::string &host,
                           const std::unordered_set<std::string> &domains,
                           std::string *matched = nullptr) {
  const std::string lower = ToLowerASCII(host);
  size_t start = 0;
  while (true) {
    const std::string candidate = lower.substr(start);
    if (domains.count(candidate) > 0) {
      if (matched) {
        *matched = candidate;
      }
      return true;
    }
    size_t dot = lower.find('.', start);
    if (dot == std::string::npos) {
      break;
    }
    start = dot + 1;
  }
  return false;
}

}  // namespace

bool BRWContentBlockerShouldBlock(const std::string &profile_name,
                                  const std::string &host,
                                  std::string *matched_domain) {
  const BlockerSnapshot *snapshot = g_snapshot.load(std::memory_order_acquire);
  if (!snapshot || host.empty()) {
    return false;
  }

  auto profile_it = snapshot->profile_settings.find(profile_name);
  if (profile_it == snapshot->profile_settings.end() || !profile_it->second.enabled) {
    return false;
  }

  if (IsHostOrAncestorInSet(host, profile_it->second.allowlisted_hosts)) {
    return false;  // Allowlist always wins.
  }
  return IsHostOrAncestorInSet(host, snapshot->blocked_domains, matched_domain);
}

@implementation BRWProfileBlockingSettings {
 @public
  BOOL _enabled;
  NSArray<NSString *> *_allowlistedHosts;
}

- (instancetype)initWithEnabled:(BOOL)enabled allowlistedHosts:(NSArray<NSString *> *)allowlistedHosts {
  self = [super init];
  if (self) {
    _enabled = enabled;
    _allowlistedHosts = [allowlistedHosts copy];
  }
  return self;
}

@end

@implementation BRWContentBlocker

+ (void)updateWithBlockedDomains:(NSArray<NSString *> *)blockedDomains
                  profileSettings:(NSDictionary<NSString *, BRWProfileBlockingSettings *> *)profileSettings {
  auto snapshot = std::make_unique<BlockerSnapshot>();

  snapshot->blocked_domains.reserve(blockedDomains.count);
  for (NSString *domain in blockedDomains) {
    snapshot->blocked_domains.insert(ToLowerASCII(ToStdString(domain)));
  }

  for (NSString *profileName in profileSettings) {
    BRWProfileBlockingSettings *settings = profileSettings[profileName];
    ProfileBlockingSettings cppSettings;
    cppSettings.enabled = settings->_enabled;
    cppSettings.allowlisted_hosts.reserve(settings->_allowlistedHosts.count);
    for (NSString *host in settings->_allowlistedHosts) {
      cppSettings.allowlisted_hosts.insert(ToLowerASCII(ToStdString(host)));
    }
    snapshot->profile_settings[ToStdString(profileName)] = std::move(cppSettings);
  }

  // Deliberately leaked -- see this file's top-of-file comment.
  g_snapshot.store(snapshot.release(), std::memory_order_release);
}

@end
