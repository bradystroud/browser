#!/usr/bin/env bash
# Builds the update install helper (Packages/UpdateCore's BrowserUpdateAgent)
# and signs it into <app>/Contents/MacOS/BrowserUpdateAgent.
#
# Run it before scripts/sign.sh, never after: the main app's signature seals
# every executable in Contents/MacOS. The helper is signed with its own
# identifier, which the updater checks before it ever runs one
# (ApplicationUpdate.agentIdentifier).
#
# Usage: scripts/bundle-update-agent.sh <path/to/Browser.app> [codesign identity]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$1"
IDENTITY="${2:--}"

swift build --package-path "${ROOT_DIR}/Packages/UpdateCore" -c release --product BrowserUpdateAgent
AGENT="${APP_PATH}/Contents/MacOS/BrowserUpdateAgent"
cp "${ROOT_DIR}/Packages/UpdateCore/.build/release/BrowserUpdateAgent" "${AGENT}"
codesign --force --options runtime --timestamp --sign "${IDENTITY}" \
  --identifier dev.stroud.browser.update-agent "${AGENT}"
echo "update helper bundled: ${AGENT}"
