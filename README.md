# Browser

A native macOS browser: Chromium (via [CEF](https://bitbucket.org/chromiumembedded/cef)) in a Swift/AppKit shell, with separate profiles and rule-based link routing.

**[Website](https://bradystroud.github.io/browser/)** · **[Download](https://github.com/bradystroud/browser/releases/latest/download/Browser.dmg)** · **[Releases](https://github.com/bradystroud/browser/releases)**

## Install

Browser needs macOS 12 Monterey or later on Apple silicon. Each release is signed with a Developer ID and notarized by Apple, so macOS opens it without a Gatekeeper warning.

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
