#!/bin/bash
# Install the built app to /Applications and (re)register it with Launch Services.
# Launch Services only offers apps as default-browser candidates from a stable
# installed location — running from build/ is invisible to the default-browser list.
set -euo pipefail

APP_SRC="$(cd "$(dirname "$0")/.." && pwd)/build/Sources/App/Release/Browser.app"
APP_DST="/Applications/Browser.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

[ -d "$APP_SRC" ] || { echo "Build first: ./scripts/build.sh" >&2; exit 1; }

# Never leave two instances sharing the same root_cache_path.
osascript -e 'tell application "Browser" to quit' 2>/dev/null || true
sleep 2

rm -rf "$APP_DST"
ditto "$APP_SRC" "$APP_DST"
"$LSREGISTER" -f "$APP_DST"
echo "Installed $APP_DST"
