# SearchCore

Standalone SwiftPM package (pure Swift/Foundation, no AppKit/CEF
dependency) holding the omnibox's search logic for bead `browser-0du`:
search-engine choice, the URL-versus-query decision, suggestion parsing,
and Quick Website Search.

Like `RoutingCore` and `Packages/BrowserCore`, these same source files are
also added directly to `Sources/App/CMakeLists.txt`'s compile list, so the
app builds the identical logic with no SwiftPM dependency edge -- one copy
of the logic, two ways to build it. This package exists so the logic is
runnable and testable on its own.

## What's here

- **`OmniboxInputClassifier`** -- "is this typed text a URL or a search?".
  The single most error-prone decision the omnibox makes, and the reason
  this package exists at all. It follows Chromium where Chromium is
  settled, and errs toward searching where it is not: a search for
  something meant as a URL costs one click, while navigating to something
  meant as a search sends the user to a stranger's server. See the type's
  doc comment, and `OmniboxInputClassifierTests` for the full table of
  awkward cases it is pinned against -- `localhost:3000`, `3.14`,
  `and/or`, `10:30`, `[::1]:8080`, `münchen.de`, `view-source:`,
  `javascript:`, `someone@example.com`.
- **`SearchEngine`** -- an engine as a search template plus an optional
  suggestion template, with Google/DuckDuckGo/Bing/Kagi built in and a
  validated custom template. Query substitution percent-encodes to the RFC
  3986 unreserved set, so a query containing `&`, `=` or `#` can never
  rewrite the template's own parameters.
- **`OmniboxResolver`** -- puts the three decisions together in the one
  order they can happen in: URL or search, which engine, and whether a
  Quick Website Search keyword claims the input.
- **`SearchSuggestionParser`** -- OpenSearch suggestion JSON
  (`["typed", ["first", "second"]]`), which is what all four built-in
  engines answer with, plus DuckDuckGo's object form.
- **`QuickSiteSearch`** -- derives `keyword -> template` pairs from
  visited URLs that carry a search parameter, and matches "keyword query"
  typed into the omnibox against them.

## What is deliberately not here

- **Anything that touches the network.** Fetching suggestions is
  `Sources/App/Omnibox/SearchSuggestionFetcher.swift`, which also enforces
  the privacy rules (opt-in, never in a private window). This package only
  builds the URL and parses the answer.
- **Storage.** Quick Website Search keywords are derived from the existing
  history database at read time (`QuickSiteSearchCatalog` in the app), not
  stored separately -- a second copy would be a second thing to delete
  when the user clears their history.

## Running the tests

```
cd Packages/SearchCore && swift test
```
