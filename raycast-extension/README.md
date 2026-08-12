# Browser Profiles — Raycast extension

A local-only Raycast extension that drives this repo's `browser` CLI, so you can
open links and windows in a specific profile without touching the app's UI.

**Not published, and not meant to be.** It talks to a CLI that only exists on a
machine with this browser installed, so it would be useless to anyone else.
`npm run publish` is deliberately wired to fail.

## Commands

| Command                           | What it does                                                                          |
| --------------------------------- | ------------------------------------------------------------------------------------- |
| **Switch to Profile**             | Pick a profile and land in it: focuses its frontmost window, or opens one if it has none. |
| **Open Link in Profile**          | Type/paste a URL, pick a profile (or let routing rules decide), tab or new window.      |
| **New Window in Profile**         | Pick a profile, get an empty new window in it.                                          |
| **Open Clipboard Link in Profile**| Uses the selected text if there is any, else the clipboard; pick a profile to open in.  |
| **Search Browser History**        | Live search of a profile's history; open any hit in any profile.                        |
| **Search Bookmarks**              | Loads a profile's bookmark tree and filters it; open any hit in any profile.            |

"Use routing rules" in the open commands sends no `--profile`, which puts the URL
through the same `RuleMatcher`/`RoutingCoordinator` path a link clicked in another
app takes. Picking a profile explicitly bypasses the rules.

## Setup

```
cd raycast-extension
npm install
npm run dev        # opens the commands in Raycast, hot-reloading
```

`npm run dev` keeps running and Raycast keeps the extension installed once you
stop it. `npm run lint` (Prettier + ESLint + manifest/icon validation) and
`npx tsc --noEmit` are the checks worth running before committing changes.

## Requirements

- **The `browser` CLI on disk.** The extension looks for it at
  `/usr/local/bin/browser`, then
  `/Applications/Browser.app/Contents/Resources/bin/browser`. `scripts/build.sh`
  builds and signs it into the bundle; symlink it once with
  `ln -sf "/Applications/Browser.app/Contents/Resources/bin/browser" /usr/local/bin/browser`.
  Raycast does not inherit a login shell's `PATH`, so the extension always
  resolves an absolute path — a `browser` that works in your terminal via some
  other `PATH` entry won't be found unless you set the preference below.
- **Browser.app running**, for everything except history and bookmarks (those read
  each profile's `browser.db` directly and work with the app closed). Profile
  lists come from the running app, so with nothing running every command shows a
  "Browser isn't running" toast.

## Preferences

- **Browser CLI Path** — override the two paths above.
- **Profiles Root** — only for pointing the extension at a scratch instance
  launched with `--profiles-root`. Leave blank for your normal install.

## Why a CLI wrapper rather than AppleScript

The app has no scripting dictionary, and this repo bans agents from driving its
UI with System Events (see `CLAUDE.md`). The `browser` CLI (browser-82d) already
exists as the sanctioned control surface, and gained `window new` / `windows` /
`open --new-window` for this extension — so Raycast gets a stable, testable
contract instead of synthetic keystrokes. See.
