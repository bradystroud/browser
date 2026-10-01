# Browser Profiles — Raycast extension

Open links and new windows in a chosen profile of
[Browser](https://bradystroud.github.io/browser/), and search its history and
bookmarks, without leaving Raycast. It drives the `browser` command-line tool
that ships inside Browser.app, so there is nothing else to install.

## Commands

| Command                            | What it does                                                                              |
| ---------------------------------- | ----------------------------------------------------------------------------------------- |
| **Switch to Profile**              | Pick a profile and land in it: focuses its frontmost window, or opens one if it has none. |
| **Open Link in Profile**           | Type or paste a URL, pick a profile (or let your link rules decide), tab or new window.   |
| **New Window in Profile**          | Pick a profile, get an empty new window in it.                                            |
| **Open Clipboard Link in Profile** | Uses the selected text if there is any, else the clipboard; pick a profile to open it in. |
| **Search Browser History**         | Live search of a profile's history; open any result in any profile.                       |
| **Search Bookmarks**               | Loads a profile's bookmarks and filters them; open any result in any profile.             |

"Use routing rules" in the open commands sends the link through the same rules
a link clicked in another app goes through. Picking a profile explicitly
bypasses the rules.

## Requirements

- **macOS** with [Raycast](https://www.raycast.com/).
- **Browser.app** in `/Applications` or `~/Applications`
  ([download](https://bradystroud.github.io/browser/#install)). Switch to
  Profile needs a Browser newer than 0.1.0; every other command works with 0.1.0.
- To install from source (below): **Node.js 22.22 or later** and npm, and `git`.

## Install from source

The extension is not in the Raycast Store yet. Until it is, install it from
this repository:

```sh
git clone --depth 1 https://github.com/bradystroud/browser.git
cd browser/raycast-extension
npm install
npm run dev
```

`npm run dev` builds the extension and imports it into Raycast; its six
commands then show up when you search Raycast for "profile", "bookmarks" or
"history". Stop it with Ctrl-C once they appear: **the extension stays
installed in Raycast after you stop it**, so no terminal needs to stay open.
Keep the cloned folder, though — Raycast loads the extension from it.

Only the extension's own folder is needed. To skip downloading the rest of the
app's source:

```sh
git clone --depth 1 --filter=blob:none --sparse https://github.com/bradystroud/browser.git
cd browser
git sparse-checkout set raycast-extension
cd raycast-extension
npm install
npm run dev
```

### Updating

```sh
cd browser
git pull
cd raycast-extension
npm install
npm run dev     # rebuilds and re-imports; Ctrl-C when done
```

### Removing

In Raycast, search for any of the extension's commands, press ⌘K and choose
**Uninstall Extension**. Then delete the cloned folder.

## Preferences

Both are optional; leave them blank for a normal install.

- **Browser CLI Path** — where to find the `browser` tool. By default the
  extension looks at `/usr/local/bin/browser` (if you linked it there for
  terminal use), then inside `Browser.app` in `/Applications`, then in
  `~/Applications`. Raycast does not use your shell's `PATH`, so a `browser`
  that works in your terminal some other way will not be found unless you put
  its full path here.
- **Profiles Root** — only for developers pointing the extension at a test
  instance launched with `--profiles-root`.

## Troubleshooting

| Message                     | What to do                                                                                                                                                                         |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Browser isn't installed** | Browser.app is in neither `/Applications` nor `~/Applications`. Install it, or set **Browser CLI Path** to `<where it is>/Browser.app/Contents/Resources/bin/browser`.             |
| **Browser isn't running**   | Launch Browser and try again. Profile lists and opening links need the running app; history and bookmark search read saved data and still work, but only for the fallback profile. |
| **Browser needs an update** | Your Browser is older than the extension. Install the latest from the [download page](https://bradystroud.github.io/browser/#install).                                             |
| **No profiles**             | Same as "isn't running": the profile list is read live from the app.                                                                                                               |
| Commands missing in Raycast | Run `npm run dev` again in `raycast-extension` and wait for "built extension successfully". If `npm install` failed, check `node --version` is 22.22 or later.                     |

## Development

`npm run dev` hot-reloads while it runs. Before committing, run
`npm run lint` (Prettier, ESLint, and manifest/icon validation),
`npm run build`, and `npx tsc --noEmit`.

The app has no AppleScript dictionary and its UI is not meant to be driven by
synthetic keystrokes, so the `browser` CLI is the extension's only interface
to the app. That gives Raycast a stable, testable contract: every command is a
single `browser … --json` call (bookmarks walk the folder tree with one call
per folder). The CLI never exposes saved passwords, so neither does this
extension.
