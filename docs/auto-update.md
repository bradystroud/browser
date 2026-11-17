# Auto-update

Browser updates itself from its GitHub releases. It does not use Sparkle or
an appcast. The design is a port of myterm's updater.

## What the user sees

1. Once a day, a release build asks GitHub for the newest release
   (`api.github.com/repos/bradystroud/browser/releases/latest`).
2. When that release is newer, a button appears in every window's toolbar.
   No dialog opens by itself.
3. The button, or Browser > Check for Updates…, opens the update dialog:
   Release Notes, Skip This Version, Later and Update Now.
4. Update Now downloads the release's `Browser-<version>.dmg`, verifies it and
   stages the app beside the installed one. The installed app does not change.
5. Restart Now installs the update and opens the new version. Later installs it
   the next time Browser quits.

Settings > General > Updates turns the daily check off, shows the installed
version, and has Check Now.

## What is checked

The trust anchor is the code signature, not the download location.

- The DMG's SHA-256 must equal the `digest` that GitHub's API lists for the
  asset, and the asset URL must be exactly
  `github.com/bradystroud/browser/releases/download/<tag>/Browser-<version>.dmg`.
- The DMG and the app inside it must carry a Developer ID signature from team
  `AQ6HPWB3D9`, and Gatekeeper must report "Notarized Developer ID" for both.
- The app must have bundle ID `dev.stroud.browser`, the release's version, the
  `BRWReleaseBuild` key, an arm64 executable, and a signed install helper.

The same checks run again just before the swap.

## How it installs

The pieces are in `Packages/UpdateCore` (with tests: `cd Packages/UpdateCore && swift test`)
and `Sources/App/Update/`.

- The release is staged in a private folder beside the app:
  `<Applications>/.browser-update-<UUID>.noindex/` (mode 0700). The folder that
  holds the app must be writable.
- `BrowserUpdateAgent` (in `Contents/MacOS`) is copied into that folder. At
  quit or restart, Browser starts it with the folder's `update.json` and its
  own PID.
- The helper waits for Browser to exit, checks everything again, and swaps the
  two bundles in one step (`renameatx_np` with `RENAME_SWAP`). The previous
  app stays whole in the staging folder.
- For a restart, the helper opens the new version and waits up to 120 seconds
  for it to confirm its startup (`UpdateStartupTrial`). If it does not
  confirm, the helper stops it, swaps the previous app back and opens that.
- An install at quit has no one to wait for. The next launch confirms it.
  Until then the staging folder keeps the previous app.
- A failure is written to `install-error.txt` in the staging folder. The next
  launch shows it in the update dialog.
- Finished staging folders are deleted at launch.

## Which builds update

Only builds made by `scripts/release.sh` with a real identity. They carry
`BRWReleaseBuild` in Info.plist and the helper in `Contents/MacOS`.

- A local build (`scripts/build.sh`, the `ship` skill) has the template
  version from `Info.plist.in`, so it would always look out of date. It never
  checks by itself, and it never installs. Check Now still shows the newest
  release and opens its page.
- A scratch launch (`--profiles-root`) and a bundle in the build folder have
  updates turned off completely.

## Release requirements

`scripts/release.sh` signs the DMG before it notarizes it, and the workflow
uploads `Browser-<version>.dmg`. The updater needs both.

A copy installed with Homebrew updates itself the same way. Homebrew's own
record then shows the old version until `brew upgrade` runs, which is
harmless. The cask should say `auto_updates true`, so that `brew upgrade`
does not try to replace an app that already updated itself.
