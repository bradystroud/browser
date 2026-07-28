import Foundation

/// A small starter phishing/malware domain list -- ships with the app so
/// the warning feature (browser-12m.6) has *something* loaded and is
/// verifiable end-to-end offline, without requiring a remote feed fetch
/// first. See `ThreatList`'s doc comment for how this is loaded (the same
/// `BlockList`/`ListParser` machinery as the ad/tracker list, as a second,
/// independent instance).
///
/// This is deliberately much smaller and differently-sourced than
/// `starterBlockListText`, and that difference is worth being explicit
/// about rather than papering over: ad-tech domains (doubleclick.net,
/// googlesyndication.com, ...) are corporate infrastructure that stays
/// stable for years, so a hand-curated list of a few hundred of them is a
/// real, durable starting point. Phishing/malware domains are the opposite
/// -- they're overwhelmingly disposable, registered and abandoned within
/// days, so there is no equivalent "these few hundred domains have been
/// bad actors for years" list to hand-curate honestly. Hardcoding a large
/// list of "known phishing domains" from memory would mean shipping
/// entries that are very likely already stale, and -- worse -- could
/// mislabel a domain that's since changed hands to an unrelated, innocent
/// owner. Given that, this starter list intentionally contains only
/// Google's own official Safe Browsing test domains (safe, real, and
/// designed by Google specifically for verifying an integration like this
/// one actually works end-to-end -- see docs/ai-tasks for the manual test
/// steps that use them), not a claim of any real-world phishing/malware
/// coverage.
///
/// Real-world coverage is meant to come from wiring `RemoteListSource`
/// (see that protocol's doc comment) against an actual, continuously
/// updated feed -- URLhaus, OpenPhish, and Phishing.Database are the
/// realistic public options if a refresher job is ever built; that's a
/// deliberately separate, not-yet-started follow-up (see `bd show
/// browser-12m.6`'s notes), not something this starter list attempts to
/// substitute for.
public let starterThreatListText = """
# Google's official Safe Browsing test infrastructure -- safe, not real
# malware/phishing, provided by Google specifically to let an integration
# like this one verify it actually shows a warning end-to-end. See
# https://testsafebrowsing.appspot.com and
# https://developers.google.com/safe-browsing for Google's own documented
# per-threat-type test URLs under this host.
testsafebrowsing.appspot.com

# Google's older, still-documented literal test domain for exercising a
# "malware ahead" warning (distinct from the JS-driven test page above).
malware.testing.google.test
"""
