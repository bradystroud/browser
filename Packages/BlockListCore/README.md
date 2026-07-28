# BlockListCore

Standalone SwiftPM package (pure Swift/Foundation, no AppKit/CEF dependency)
implementing the domain-matching core for Browser's built-in ad/tracker
content blocker (M7 epic, bead `browser-12m.5`). **Phase 1 only** -- this
package has zero wiring into the app yet; see "Phase 2" below.

## What's here

- **`DomainTrie`** -- a reversed-label trie answering "is host H, or any
  ancestor domain of H, in this set?" in O(labels in H), with memory shared
  across common suffixes (100k domains sharing TLDs/eTLDs cost far less
  than 100k independent strings). Storing an exact domain implicitly
  blocks every subdomain of it, without needing separate entries -- see
  the type's doc comment for exactly how the single lookup walk does this.
- **`BlockList`** -- wraps one shared `DomainTrie` of blocked domains,
  loaded via `load(_:)` (raw text) or `loadStarterList()`.
- **`ListParser`** -- parses two curated-list formats: hosts-file style
  (`0.0.0.0 ads.example.com`, `#` comments, multiple hostnames per line)
  and plain domain-per-line (OISD "domains only" style). **Deliberately
  does not parse EasyList/Adblock Plus cosmetic-filter syntax**
  (`##selector`, `$third-party` options, etc.) -- that's a materially
  different, much larger parsing problem (cosmetic element-hiding rules
  need a CSS-rule engine, not a domain matcher), and this blocker only
  ever blocks/allows whole requests by host, never hides page elements.
- **`BlockingSettings`** -- the tiny per-profile Codable model: a master
  `isEnabled` switch and `allowlistedHosts` ("turn off blocking on this
  site"). Deliberately separate from `BlockList` itself: the block list is
  shared/global (built once, potentially 100k+ entries), while this is
  what varies per profile. `BlockingSettings.shouldBlock(host:blockList:)`
  combines the two: disabled -> never blocks; allowlisted (subdomain-
  inclusive, same semantics as `DomainTrie`) -> never blocks even if also
  in the block list; otherwise -> `blockList.contains(host:)`.
- **`starterBlockListText`** -- a small (~150-entry), hand-curated,
  high-confidence starter list of well-established ad/tracker
  infrastructure domains, embedded as a plain Swift string constant (see
  "Why a string constant, not a bundled resource" below). Ships so
  blocking works offline out of the box; not a claim of comprehensive
  coverage -- loading a full curated list (OISD, StevenBlack) via
  `load(_:)` is the intended primary path for real-world coverage.
- **`RemoteListSource`** -- a *stubbed interface only* (no implementation)
  for a future remote list fetch with ETag-based conditional requests.
  Pins down the shape Phase 2 needs to build against; see "Remote list
  refresh" below.

## Why a string constant, not a bundled resource file

RoutingCore and BrowserCore (this package's siblings under `Packages/` and
the repo root) are compiled two ways: as a standalone SwiftPM package
(`swift test`) *and* by having their same source files added directly to
`Sources/App/CMakeLists.txt`'s compile-sources list, so the app target
builds the identical logic without a real SwiftPM dependency edge (see
those packages' own doc comments for the full reasoning). A `resources:`
entry in `Package.swift` -- and the `Bundle.module` lookup that goes with
it -- only works through SwiftPM's own resource-bundling machinery; it has
no equivalent when a source file is just added to a CMake target's source
list. Embedding the starter list as a Swift string literal keeps this
package followable by that exact same "compile the same files two ways"
pattern once Phase 2 wires it in, with no resource-bundle plumbing to
replicate on the CMake side.

## Running the tests

```
cd Packages/BlockListCore && swift test
```

## Phase 2 (follow-up, not done here)

Wiring this into the running browser needs, roughly:

1. **Request interception**: implement a `CefResourceRequestHandler` (or
   extend the existing client handler in `Sources/Bridge/`) and override
   `OnBeforeResourceLoad`. For each outgoing request, extract the request
   URL's host, ask `BlockingSettings.shouldBlock(host:blockList:)` (the
   active profile's settings + one process-wide shared `BlockList`), and
   return `RV_CANCEL` when true -- CEF's documented way to cancel a
   request outright, distinct from redirecting it. This callback fires on
   CEF's IO thread, not the UI thread; `DomainTrie.contains` is a pure,
   read-only walk over already-built nodes, so it's safe to call from
   there as long as list mutation (loading/reloading) is synchronized
   separately if it ever needs to happen after browsers are already
   issuing requests.
2. **App-side wiring**: one shared `BlockList` built at launch (loading the
   starter list, later a cached remote list), and a `BlockingSettings`
   value stored per profile -- same JSON-under-`~/Library/Application
   Support/Browser/` pattern as `RoutingRulesStore`/`ProfileManager`.
3. **Toolbar badge**: a per-tab (or per-window) blocked-request counter,
   incremented each time `OnBeforeResourceLoad` cancels a request for that
   browser, surfaced as a small badge/count in the toolbar -- mirrors
   other browsers' "N trackers blocked on this page" indicator. Needs a
   `BRWBrowserDelegate`-style callback so the count reaches Swift/AppKit
   without CEF types leaking into the UI layer, per this repo's
   engine-agnostic-UI principle (see root `AGENTS.md`).
4. **Settings UI**: a "Privacy" section in the Settings window (see
   `SettingsWindowController`) -- master on/off toggle, and a way to
   view/remove per-site allowlist entries. A one-click "allow this site"
   action from the toolbar is the more important UX to get right first; a
   plain remove button next to each entry in Settings covers the rest.
5. **Remote list refresh**: `ListParser`/`BlockList` are already
   text-in/domain-out, so this only needs an actual fetch step --
   implement `RemoteListSource` against a real URL + ETag cache
   (conditional GET, re-parse only on 200, keep the last-known-good list
   on any fetch failure).

Phase 2 is filed as a follow-up bead linked to `browser-12m.5` (see `bd
show browser-12m.5` for the link) -- this package's job stops at "block
list Phase 1" per the task that produced it.
