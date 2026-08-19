# Auto-update (Sparkle)

Browser is distributed outside the App Store, so nothing updates it unless it
updates itself. This is how that works, and what a release now requires.

Tracked as beads `browser-wc7`.

## Shape of it

- The app embeds **Sparkle 2.9.6** (`third_party/sparkle/`, fetched by
  `scripts/fetch-sparkle.sh`, gitignored exactly like CEF).
- It polls **https://bradystroud.github.io/browser/appcast.xml** — the file
  at `docs/appcast.xml`, which GitHub Pages already serves alongside the
  landing page. No new hosting.
- Each appcast entry points at the **GitHub release DMG** for that version.
- Sparkle refuses any download whose **EdDSA signature** does not verify
  against the `SUPublicEDKey` baked into the installed app. That is what
  makes it safe to serve the feed from a static host: a compromised feed
  cannot make an installed copy run anything Brady did not sign.

App-side wiring is `Sources/App/Update/UpdateCoordinator.swift`, started last
in `AppDelegate.applicationDidFinishLaunching`. Publishing-side logic is
`Packages/UpdateCore` (`swift test`), driven by `scripts/release.sh`.

## One-time setup — Brady, by hand, once

Auto-update is **off in every build** until this is done. `UpdateCoordinator`
recognises the placeholder key in `Info.plist` and never starts the updater,
so nothing about a dev build changes in the meantime.

1. Generate the signing keypair. The private half goes into the login
   Keychain and must never enter this repo:

   ```
   ./third_party/sparkle/bin/generate_keys
   ```

   It prints the public key, as a base64 string.

2. Paste that public key into `Sources/App/mac/Info.plist.in`, replacing
   `REPLACE_WITH_SUPublicEDKey_FROM_generate_keys`:

   ```xml
   <key>SUPublicEDKey</key>
   <string>...the printed base64 public key...</string>
   ```

3. Commit that change. From this point every build has auto-update live.

**Back the private key up.** Losing it means no already-installed copy can
ever be updated again — they will reject every future release, and the only
way out is asking every user to re-download by hand. Export it with
`./third_party/sparkle/bin/generate_keys -x <file>` and put that file
somewhere safe and offline. Never in this repo; it is public.

## Cutting a release

1. Bump `CFBundleVersion` **and** `CFBundleShortVersionString` in
   `Sources/App/mac/Info.plist.in`. Sparkle compares `CFBundleVersion`
   against the appcast's `<sparkle:version>`; a release that forgets this
   ships a build no installed copy considers newer than what it has.

2. Run the pipeline as before, in dmg format:

   ```
   scripts/release.sh --identity "Developer ID Application: Brady Stroud (AQ6HPWB3D9)" --format dmg
   ```

   After stapling it now also signs the finished DMG with `sign_update` and
   writes the entry into `docs/appcast.xml`. It prints the download URL it
   assumed.

3. Create the GitHub release with tag `v<version>` and upload the DMG under
   exactly the filename in that URL. **The signature covers those exact
   bytes** — re-generating or re-compressing the DMG after this step
   invalidates it.

4. Commit and push `docs/appcast.xml`. Pages redeploys, and installed copies
   pick the update up on their next check (within 24h) or immediately from
   "Check for Updates…".

Re-cutting a release that already has an appcast entry is fine: the entry is
replaced, not duplicated.

## What is deliberately not automated

`scripts/release.sh` does not create the GitHub release, upload the asset, or
push the appcast. Publishing is Brady's call, and an update feed that goes
live before its download exists points every installed copy at a 404.

## Updates are off for some launches, on purpose

`UpdateCoordinator.disabledReason()` keeps the updater from starting when:

- `--profiles-root` was passed — a scratch/test instance, which is what
  `scripts/launch-scratch.sh` and every agent produces. Those are throwaway
  copies under `/tmp`.
- the bundle is inside the CMake output tree (`build/`, `build-release/`) —
  Sparkle would otherwise swap the code under development for the last
  published release.
- `SUPublicEDKey` is missing or still the placeholder.

Each case logs one line saying which, so "why did it not check?" is
answerable from the log rather than by reading this file.

## Profiles survive an update

All state lives in `~/Library/Application Support/Browser/` (see
`BrowserCore`'s `ProfilesRootResolver`) — history, bookmarks, downloads,
cookies, profile metadata, session. Sparkle replaces only the `.app` bundle,
so an update cannot touch any of it. This is `browser-le4`'s guard rail #4,
and it holds structurally rather than by care.

## Signing, and the trap next to it

`scripts/sign.sh` signs Sparkle inside-out before the app itself:
`Downloader.xpc`, `Installer.xpc`, `Updater.app`, `Autoupdate`, then the
framework. Every one is separately sealed code that `codesign` will not reach
on its own, and `release.sh`'s existing gate fails the release if any Mach-O
in the bundle lacks a Developer ID signature and secure timestamp.

The framework is copied into the bundle with `ditto`, **not** CMake's
`copy_directory`. `copy_directory` is what leaves the broken self-referential
symlinks inside the CEF framework that `sign.sh` has to prune — and a broken
symlink anywhere in the bundle is a Gatekeeper rejection ("invalid
destination for symbolic link in bundle") that shows up only on a
*downloaded* copy, never on a locally built one. `ditto` reproduces the
vendor framework faithfully, so there is nothing to prune.
