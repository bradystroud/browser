#!/bin/bash
# Screenshot a specific Browser instance's window by PID, without focus changes.
#
# Captures via window ID, so it works even when the window is behind another
# app's (or offscreen under --test-no-activate) — never brings a window
# forward, never touches whatever else is on screen. Use this instead of a
# fullscreen screencapture, which would capture Brady's real browsing.
#
# usage: ./scripts/shot-window.sh <pid-of-your-test-instance> <out.png>
set -euo pipefail
PID="${1:?usage: shot-window.sh <pid> <out.png>}"
OUT="${2:?usage: shot-window.sh <pid> <out.png>}"
HELPER="$(cd "$(dirname "$0")" && pwd)/.window-id"
SRC="$(cd "$(dirname "$0")" && pwd)/window-id.swift"
[ -x "$HELPER" ] || swiftc -O "$SRC" -o "$HELPER"
WIN="$("$HELPER" "$PID")"
[[ "$WIN" =~ ^[0-9]+$ ]] || { echo "no window found for pid $PID ($WIN)" >&2; exit 1; }
screencapture -x -o -l"$WIN" "$OUT"
echo "wrote $OUT (window $WIN, pid $PID)"
