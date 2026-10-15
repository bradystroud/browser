#!/usr/bin/env bash
# Builds the `browser` CLI (browser-cli/, a standalone SwiftPM executable) and
# signs it into <app>/Contents/Resources/bin/browser.
#
# Run it before scripts/sign.sh, never after: adding a file to an
# already-signed bundle breaks the app's resource seal. The CLI is signed on
# its own as well, so it still runs as a normal signed executable when it is
# symlinked onto PATH, outside the bundle.
#
# Usage: scripts/bundle-cli.sh <path/to/Browser.app> [codesign identity]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$1"
IDENTITY="${2:--}"

swift build --package-path "${ROOT_DIR}/browser-cli" -c release
CLI_BIN_DIR="${APP_PATH}/Contents/Resources/bin"
mkdir -p "${CLI_BIN_DIR}"
cp "${ROOT_DIR}/browser-cli/.build/release/browser" "${CLI_BIN_DIR}/browser"
codesign --force --options runtime --timestamp --sign "${IDENTITY}" "${CLI_BIN_DIR}/browser"
echo "browser CLI bundled: ${CLI_BIN_DIR}/browser"
