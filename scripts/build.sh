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

echo "== Signing (inside-out, ad-hoc by default; see scripts/sign.sh) =="
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
