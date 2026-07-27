# browser

A macOS browser: Chromium (via CEF) rendering inside a native Swift/AppKit shell, with first-class profiles and rule-based link routing (open a link in a specific profile based on domain and/or source app).

## Architecture (decided — see docs/plans and docs/research before changing)

- **Engine:** CEF (Chromium Embedded Framework), Chrome bootstrap (the only bootstrap since M128), **Alloy-style** browser windows parented into our own `NSView` via `CefWindowInfo.SetAsChild` + `runtime_style = CEF_RUNTIME_STYLE_ALLOY`. Chrome-style windows in native NSWindows are unsupported on macOS — do not attempt it.
- **Layering:** Swift/AppKit UI (tab strip, omnibox, settings) → thin Obj-C++ (`.mm`) bridge exposing Obj-C interfaces → CEF C++ API (`libcef_dll_wrapper`). No CEF types leak into Swift.
- **Engine-agnostic UI (standing principle):** UI/shell code must treat the engine as swappable — a WebKit backend is a tracked future option. New UI code programs against the engine-neutral surface (today the `BRW*` Obj-C interfaces; a formal `BrowserEngine`/`EngineTab` protocol refactor is tracked in beads), never against anything CEF-specific. Engine-specific behavior, flags, and workarounds live behind the bridge, not in Swift. If a feature seems to need CEF details in UI code, extend the bridge interface instead.
- **Profiles:** one `CefRequestContext` per profile, each with its own `cache_path`; **all cache paths must live under the shared `CefSettings.root_cache_path`** (CEF crashes otherwise).
- **Link routing:** app registers as default browser (`kAEGetURL` Apple Event); sender app resolved via `keySenderPIDAttr` → `NSRunningApplication`. Rules: domain glob + URL regex + source bundle ID, AND across present fields, first match wins, default-profile fallback.
- **Distribution:** Developer ID + notarization only. **Never App Sandbox** — sandboxing breaks default-browser registration. No Mac App Store.
- **Passkeys:** QR/hybrid + security keys work via Chromium's stack; Touch ID / iCloud Keychain requires Apple's restricted `com.apple.developer.web-browser.public-key-credential` entitlement (application pending — see plan).

## UI verification protocol (Brady tests, agents don't drive his machine)

Do NOT drive the app's UI with osascript/System Events/keystroke automation — it's flaky here, interferes with Brady's own use of the app, and he prefers testing UI himself. Agents verify what's verifiable non-interactively (build green, unit tests, code review of the key path, log output), then END their report with a manual test hand-off in exactly this shape:

**Test:** (numbered steps — what to do)
**Expect:** (what should happen at each step)
**Report:** (what to tell us, especially the failure signals to look for)

Launching the app to confirm it starts, and reading logs/crash reports, is fine. Screenshot-only passive capture is fine. Sending synthetic clicks/keystrokes is not.

## Conventions

- Plans live in `docs/plans/`, filenames `YYYY-MM-DD-TOPIC.md`. Research reports in `docs/research/`.
- CEF binary distributions are large; they live under `third_party/cef/` and are gitignored — `scripts/fetch-cef.sh` downloads the pinned version (currently 150.0.14, macOS arm64 Standard distribution).
- The link-routing rule model + matcher (`RoutingRule`/`RuleMatcher`) live in `RoutingCore/`, a standalone SwiftPM package with its own unit tests (`cd RoutingCore && swift test`) so the matching logic can be tested independent of the full CEF/Xcode app build. `Sources/App/CMakeLists.txt` compiles those same source files directly into the Browser executable — one copy of the logic, two ways to build it. See `docs/ai-tasks/m2-routing-notes.md`.

## Build & run

```
./scripts/build.sh            # fetch-cef.sh (if needed) -> cmake -G Xcode -> build -> sign inside-out
open build/Sources/App/Release/Browser.app --args --profile default
```

`scripts/build.sh` always builds the Release configuration; pass `Debug` as `$1` to build that instead. Signing is ad-hoc (`CODESIGN_IDENTITY=-`) by default, which is fine for local dev — override `CODESIGN_IDENTITY` for a real Developer ID build. See `docs/ai-tasks/m0-spike-notes.md` for the M0 spike's findings (a per-profile Keychain "Chromium Safe Storage" prompt is worked around via `--use-mock-keychain` for ad-hoc-signed builds; that switch should come out once this ships with a real Developer ID signature), `docs/ai-tasks/m1-shell-notes.md` for the M1 shell's findings, including a fixed main-thread deadlock in `BRWMessagePump` that only surfaced when navigating an existing tab (e.g. the omnibox) — the fix (`OnScheduleMessagePumpWork` must unconditionally defer to a fresh run-loop turn, matching CEF's Mac-specific reference pump, not just the shared reference file) is worth reading before touching `Sources/Bridge/BRWMessagePump.mm` again — and `docs/ai-tasks/m2-routing-notes.md` for M2 link routing (what's verified end-to-end vs. what still needs Brady to flip the default-browser system dialog and click a real link in another app).
