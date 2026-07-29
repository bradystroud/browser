#!/usr/bin/env bash
# Clean-checkout-to-runnable-.app build: fetches CEF if needed, configures and
# builds via CMake + Xcode, then signs the result inside-out.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
CONFIG="${1:-Release}"

if [[ ! -d "${ROOT_DIR}/third_party/cef" ]] || [[ -z "$(ls -A "${ROOT_DIR}/third_party/cef" 2>/dev/null)" ]]; then
  echo "== Fetching CEF =="
  "${ROOT_DIR}/scripts/fetch-cef.sh"
fi

echo "== Configuring (CMake + Xcode generator) =="
mkdir -p "${BUILD_DIR}"
cmake -S "${ROOT_DIR}" -B "${BUILD_DIR}" -G Xcode

echo "== Building (${CONFIG}) =="
cmake --build "${BUILD_DIR}" --config "${CONFIG}" --target Browser

APP_PATH="${BUILD_DIR}/Sources/App/${CONFIG}/Browser.app"
MANIFEST="${BUILD_DIR}/Sources/App/${CONFIG}/.codesign-manifest"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "error: expected app bundle not found at ${APP_PATH}" >&2
  exit 1
fi

# Auto-detect a real Developer ID identity so the daily local build (and thus
# scripts/install.sh's daily-driver /Applications install) gets genuine
# Keychain-backed cookie/credential encryption instead of always falling
# back to ad-hoc + --use-mock-keychain (browser-35t) -- an explicit
# CODESIGN_IDENTITY (ad-hoc included, e.g. for a from-scratch clone with no
# cert yet) always wins over this and is left untouched. Only "Developer ID
# Application:" identities qualify -- this app is Developer-ID-distributed
# only (see AGENTS.md), never signed for the App Store.
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  DETECTED_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep '"Developer ID Application:' | head -1 | sed -E 's/.*"(.*)".*/\1/')"
  if [[ -n "${DETECTED_IDENTITY}" ]]; then
    echo "== Detected Developer ID identity: ${DETECTED_IDENTITY} =="
    export CODESIGN_IDENTITY="${DETECTED_IDENTITY}"
  fi
fi

# Same marker key scripts/release.sh plants before signing with a real
# identity -- see BRWCefApp.mm's OnBeforeCommandLineProcessing, the only
# reader. Guarded the same way: a no-op for the ad-hoc default.
if [[ -n "${CODESIGN_IDENTITY:-}" && "${CODESIGN_IDENTITY}" != "-" ]]; then
  INFO_PLIST="${APP_PATH}/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Delete :BRWDisableMockKeychain" "${INFO_PLIST}" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :BRWDisableMockKeychain bool true" "${INFO_PLIST}"
fi

echo "== Signing (inside-out; identity: ${CODESIGN_IDENTITY:--}; see scripts/sign.sh) =="
"${ROOT_DIR}/scripts/sign.sh" "${APP_PATH}" "${MANIFEST}"

cat <<EOF

Build complete: ${APP_PATH}

Run it:
  open "${APP_PATH}" --args --profile default

Or directly (useful for seeing stdout/stderr):
  "${APP_PATH}/Contents/MacOS/Browser" --profile default

Two-profile cookie isolation check:
  "${APP_PATH}/Contents/MacOS/Browser" --profile alice &
  "${APP_PATH}/Contents/MacOS/Browser" --profile bob &
EOF
