#!/bin/bash
# Install the built app to /Applications and (re)register it with Launch Services.
# Launch Services only offers apps as default-browser candidates from a stable
# installed location — running from build/ is invisible to the default-browser list.
set -euo pipefail

APP_SRC="$(cd "$(dirname "$0")/.." && pwd)/build/Sources/App/Release/Browser.app"
APP_DST="/Applications/Browser.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

[ -d "$APP_SRC" ] || { echo "Build first: ./scripts/build.sh" >&2; exit 1; }

# Refuse a build whose source is behind origin/main. Several agents share this
# tree, and a build from a tree that was not pulled first silently removes
# whatever already landed -- this is how shipped fixes (the profile pill,
# Touch ID passkeys) kept vanishing from the installed app. origin/main is the
# ref GitButler keeps current; nothing here fetches. BRW_ALLOW_STALE_SHIP=1
# overrides it, for deliberately installing an older build.
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILT_COMMIT="$(/usr/libexec/PlistBuddy -c "Print :BRWBuildCommit" "$APP_SRC/Contents/Info.plist" 2>/dev/null || true)"
if [ "${BRW_ALLOW_STALE_SHIP:-0}" != "1" ] && [ -n "$BUILT_COMMIT" ] \
  && git -C "$REPO_DIR" rev-parse --verify --quiet origin/main >/dev/null \
  && ! git -C "$REPO_DIR" merge-base --is-ancestor origin/main "$BUILT_COMMIT"; then
  echo "ERROR: the build ($BUILT_COMMIT) is behind origin/main, so installing it would remove:" >&2
  git -C "$REPO_DIR" log --oneline "$BUILT_COMMIT..origin/main" >&2
  echo "Run 'but pull', build again, then install. BRW_ALLOW_STALE_SHIP=1 overrides." >&2
  exit 1
fi

# Never leave two instances sharing the same root_cache_path.
osascript -e 'tell application "Browser" to quit' 2>/dev/null || true
# Wait for the process to actually exit before copying — a ditto racing a
# still-quitting instance can corrupt the installed bundle's signature.
for _ in $(seq 1 20); do
  pgrep -f "Browser.app/Contents/MacOS/Browser" >/dev/null || break
  sleep 0.5
done
pkill -f "Browser.app/Contents/MacOS/Browser" 2>/dev/null || true
sleep 1
# A hung instance can ignore SIGTERM (pre-fix builds had a quit bug that did
# exactly that) — escalate to SIGKILL and verify, or the subsequent `open`
# will just re-activate the stale running process instead of the new bundle.
if pgrep -f "Browser.app/Contents/MacOS/Browser" >/dev/null; then
  pkill -9 -f "Browser.app/Contents/MacOS/Browser" 2>/dev/null || true
  sleep 1
fi
if pgrep -f "Browser.app/Contents/MacOS/Browser" >/dev/null; then
  echo "ERROR: a Browser process refuses to die; aborting install" >&2
  exit 1
fi

rm -rf "$APP_DST"
ditto "$APP_SRC" "$APP_DST"
"$LSREGISTER" -f "$APP_DST"
echo "Installed $APP_DST"
