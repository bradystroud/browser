#!/bin/bash
# Screenshot a specific Browser instance's window by PID, without focus changes.
#
# Captures via window ID, so it works even when the window is behind another
# app's (or offscreen under --test-no-activate) — never brings a window
# forward, never touches whatever else is on screen. Use this instead of a
# fullscreen screencapture, which would capture Brady's real browsing.
#
# usage: ./scripts/shot-window.sh <pid-of-your-test-instance> <out.png> [title-substring]
#
# A single instance can own more than one real titled window at once (e.g.
# the main browser window plus the separate Settings window) -- pass a
# case-insensitive substring of the one you want (e.g. "Settings") as a
# third argument; omit it to keep the original first-match behavior. See
# window-id.swift's own doc comment, including its "--list" mode for
# figuring out what's actually available for a pid.
set -euo pipefail
PID="${1:?usage: shot-window.sh <pid> <out.png> [title-substring]}"
OUT="${2:?usage: shot-window.sh <pid> <out.png> [title-substring]}"
TITLE="${3:-}"
HELPER="$(cd "$(dirname "$0")" && pwd)/.window-id"
SRC="$(cd "$(dirname "$0")" && pwd)/window-id.swift"
# Rebuild whenever the source is newer than the cached binary (not just
# "doesn't exist yet") so edits to window-id.swift actually take effect.
[ -x "$HELPER" ] && [ "$HELPER" -nt "$SRC" ] || swiftc -O "$SRC" -o "$HELPER"
if [ -n "$TITLE" ]; then
    WIN="$("$HELPER" "$PID" "$TITLE")"
else
    WIN="$("$HELPER" "$PID")"
fi
[[ "$WIN" =~ ^[0-9]+$ ]] || { echo "no window found for pid $PID ($WIN)" >&2; exit 1; }
screencapture -x -o -l"$WIN" "$OUT"
echo "wrote $OUT (window $WIN, pid $PID)"
