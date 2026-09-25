# BlockListCore

Standalone SwiftPM package (pure Swift/Foundation, no AppKit/CEF dependency)
implementing the domain-matching core for Browser's built-in ad/tracker
content blocker (M7 epic, bead `browser-12m.5`) and threat-warning list.
The app compiles these sources directly (`Sources/App/CMakeLists.txt`) and
drives them from `ContentBlockerCoordinator` and `ThreatListCoordinator`.

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
- **Threat warnings** -- `StarterThreatList` (the bundled list of known
  dangerous domains), `ThreatWarningSettings` (the per-profile on/off
  model), `ThreatWarningLink` (the interstitial's "continue anyway" link
  format) and `ThreatWarningPageRenderer` (the interstitial page's HTML).
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

## Not done yet

`RemoteListSource` is only a protocol: the lists are the bundled starter
lists, with no remote refresh. A real source needs a fetch against a URL
with an ETag cache (conditional GET, re-parse only on 200, keep the
last-known-good list on any failure).
