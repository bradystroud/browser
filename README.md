# Browser

A native macOS browser: Chromium (via [CEF](https://bitbucket.org/chromiumembedded/cef)) in a Swift/AppKit shell, with separate profiles and rule-based link routing.

**[Website](https://bradystroud.github.io/browser/)** · **[Download](https://github.com/bradystroud/browser/releases/latest/download/Browser.dmg)** · **[Releases](https://github.com/bradystroud/browser/releases)**

## Install

Browser needs macOS 12 Monterey or later on Apple silicon. Each release is signed with a Developer ID and notarized by Apple. The first time you open it, macOS asks "Are you sure you want to open it?" and says Apple checked it for malicious software. Click **Open**. macOS asks this once for every app downloaded from the internet, including through Homebrew.

### Homebrew

```sh
brew install --cask bradystroud/tap/browser
```

Update it with `brew upgrade --cask browser`. Homebrew also puts the `browser` CLI on your `PATH`.

### Download

1. Download [Browser.dmg](https://github.com/bradystroud/browser/releases/latest/download/Browser.dmg).
2. Open it and drag **Browser** to **Applications**.
3. Open Browser from Applications.

### Make it your default browser

1. Open **Settings → Links**.
2. Click **Make Default Browser…**.
3. Add rules to send links to a profile by domain, URL pattern, or the app the link came from.

### Command-line tool (optional)

The app carries a `browser` CLI at `Browser.app/Contents/Resources/bin/browser`. Homebrew links it for you. If you installed from the DMG, link it yourself:

```sh
sudo ln -sf /Applications/Browser.app/Contents/Resources/bin/browser /usr/local/bin/browser
browser profiles
browser open https://example.com --profile Work
browser route-test https://github.com
```

For live commands (`open`, `profiles`, `tabs`, `windows`, `window new`, `focus`, and `page`), the CLI uses `--socket <absolute-path>` first, then `BROWSER_CLI_SOCKET`, then its usual per-user socket discovery. The flag works before or after the command, including nested subcommands:

```sh
browser --socket /path/to/browser.sock profiles
browser page list --socket /path/to/browser.sock --json
browser window --socket /path/to/browser.sock new
```

Explicit paths must be absolute, contain no NUL, and fit in fewer than 104 UTF-8 bytes. Invalid paths and failed connections return an error without trying another instance. Repeated `--socket` or `--profiles-root` flags are rejected. `--help` prints usage without connecting when supplied as a flag. Disk commands (`route-test`, `history search`, and `bookmarks list`) keep using `--profiles-root` for their files and reject `--socket`.

`browser socket-path` prints the resolved client socket path without connecting; `--json` returns `{"socketPath":"..."}`. To pass the normal listener path into a sandboxed AI coding client, run this in an unrestricted shell before starting the client:

```sh
export BROWSER_CLI_SOCKET="$(browser socket-path)"
# Start your AI coding client from this shell so it inherits the variable.
```

For a scratch instance, use `browser socket-path --profiles-root /path/to/scratch` in that setup command. With no socket override, `--profiles-root` selects the instance. Combining it with an inherited `BROWSER_CLI_SOCKET` returns an error: unset the variable to discover the scratch instance, or pass `--socket` explicitly to confirm the intended target. An explicit socket overrides live targeting; `--profiles-root` still selects files for disk commands.

Default discovery uses the system's per-user temporary directory. If that lookup fails, the client uses `TMPDIR`, then `/tmp` when `TMPDIR` is unset or empty. The listener's directory and security checks are unchanged. A sandbox still needs permission to connect to the selected Unix socket; setting its path does not grant that permission.

### Uninstall

```sh
brew uninstall --cask browser          # or delete /Applications/Browser.app
brew uninstall --zap --cask browser    # also delete profiles, history and settings
```

Without Homebrew, your data is in `~/Library/Application Support/Browser`. Saved passwords and cards are in your login Keychain.

## Build from source

You need Xcode 27 and CMake.

```sh
git clone https://github.com/bradystroud/browser.git
cd browser
./scripts/build.sh      # fetches CEF (~285 MB) and Sparkle, then builds and signs
./scripts/install.sh    # copies the build to /Applications
```

Without a Developer ID certificate in your keychain, the build is signed ad hoc. It runs on your Mac, but Touch ID passkeys need the signed release.

## Releases

Every push to `main` that changes the app becomes a new release. See [docs/release-automation.md](docs/release-automation.md).
