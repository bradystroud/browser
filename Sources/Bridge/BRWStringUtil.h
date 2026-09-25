// Internal C++ string and host helpers shared across the bridge's .mm
// files -- never exposed to Swift.
#pragma once

#import <Foundation/Foundation.h>

#include <string>
#include <unordered_set>

#include "include/internal/cef_string.h"

inline std::string ToStdString(NSString *s) {
  return s ? std::string([s UTF8String]) : std::string();
}

inline NSString *ToNSString(const CefString &s) {
  return [NSString stringWithUTF8String:s.ToString().c_str()];
}

inline std::string ToLowerASCII(std::string s) {
  for (char &c : s) {
    if (c >= 'A' && c <= 'Z') {
      c = static_cast<char>(c - 'A' + 'a');
    }
  }
  return s;
}

// Mirrors BlockListCore's DomainTrie.contains(host:) semantics exactly: a
// domain in `domains` matches itself and every subdomain of it, but never
// its own parent. Walks from the full host up through each ancestor domain
// (dropping one leftmost label at a time) down to the bare TLD, returning
// true as soon as any level is found in the set. `matched`, when non-null,
// receives the level that matched.
inline bool IsHostOrAncestorInSet(const std::string &host,
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
