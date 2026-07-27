# browser

A macOS browser: Chromium (via CEF) rendering inside a native Swift/AppKit shell, with first-class profiles and rule-based link routing (open a link in a specific profile based on domain and/or source app).

## Architecture (decided — see docs/plans and docs/research before changing)

- **Engine:** CEF (Chromium Embedded Framework), Chrome bootstrap (the only bootstrap since M128), **Alloy-style** browser windows parented into our own `NSView` via `CefWindowInfo.SetAsChild` + `runtime_style = CEF_RUNTIME_STYLE_ALLOY`. Chrome-style windows in native NSWindows are unsupported on macOS — do not attempt it.
- **Layering:** Swift/AppKit UI (tab strip, omnibox, settings) → thin Obj-C++ (`.mm`) bridge exposing Obj-C interfaces → CEF C++ API (`libcef_dll_wrapper`). No CEF types leak into Swift.
- **Profiles:** one `CefRequestContext` per profile, each with its own `cache_path`; **all cache paths must live under the shared `CefSettings.root_cache_path`** (CEF crashes otherwise).
- **Link routing:** app registers as default browser (`kAEGetURL` Apple Event); sender app resolved via `keySenderPIDAttr` → `NSRunningApplication`. Rules: domain glob + URL regex + source bundle ID, AND across present fields, first match wins, default-profile fallback.
- **Distribution:** Developer ID + notarization only. **Never App Sandbox** — sandboxing breaks default-browser registration. No Mac App Store.
- **Passkeys:** QR/hybrid + security keys work via Chromium's stack; Touch ID / iCloud Keychain requires Apple's restricted `com.apple.developer.web-browser.public-key-credential` entitlement (application pending — see plan).

## Conventions

- Plans live in `docs/plans/`, filenames `YYYY-MM-DD-TOPIC.md`. Research reports in `docs/research/`.
- CEF binary distributions are large; they live under `third_party/cef/` and are gitignored — `scripts/fetch-cef.sh` (once it exists) downloads the pinned version.
