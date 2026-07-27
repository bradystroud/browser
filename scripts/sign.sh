#!/usr/bin/env bash
# Inside-out codesigning for the CEF app bundle: dylibs and the framework
# first, then each helper .app (with its own entitlements), then the main app
# last. Never uses `codesign --deep` -- see AGENTS.md hard constraint #4.
#
# Ad-hoc signing (identity "-") is the default and is fine for local dev;
# override CODESIGN_IDENTITY to sign with a real Developer ID.
set -euo pipefail

APP_PATH="${1:?usage: sign.sh <path-to-Browser.app> <codesign-manifest>}"
MANIFEST="${2:?usage: sign.sh <path-to-Browser.app> <codesign-manifest>}"
IDENTITY="${CODESIGN_IDENTITY:--}"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "error: ${APP_PATH} does not exist" >&2
  exit 1
fi
if [[ ! -f "${MANIFEST}" ]]; then
  echo "error: manifest ${MANIFEST} does not exist (did the CMake configure step run?)" >&2
  exit 1
fi

sign_with_entitlements() {
  local target="$1"
  local entitlements="$2"
  codesign --force --options runtime --timestamp=none \
    --sign "${IDENTITY}" \
    --entitlements "${entitlements}" \
    "${target}"
}

FRAMEWORK_DIR="${APP_PATH}/Contents/Frameworks/Chromium Embedded Framework.framework"

if [[ ! -d "${FRAMEWORK_DIR}" ]]; then
  echo "error: CEF framework not found at ${FRAMEWORK_DIR}" >&2
  exit 1
fi

# 1. Innermost first: support dylibs inside the framework (ANGLE/SwANGLE etc).
if [[ -d "${FRAMEWORK_DIR}/Libraries" ]]; then
  while IFS= read -r -d '' lib; do
    echo "Signing (lib): ${lib}"
    codesign --force --sign "${IDENTITY}" --timestamp=none "${lib}"
  done < <(find "${FRAMEWORK_DIR}/Libraries" -type f \( -name "*.dylib" -o -name "*.so" \) -print0)
fi

# 2. The framework bundle itself.
echo "Signing (framework): ${FRAMEWORK_DIR}"
codesign --force --sign "${IDENTITY}" --timestamp=none "${FRAMEWORK_DIR}"

# 3. Helper app bundles, then the main app last -- exactly the order CMake
#    wrote into the manifest (helpers first, "app|.|..." appended last).
while IFS='|' read -r kind rel_path entitlements; do
  [[ -z "${kind}" ]] && continue
  target="${APP_PATH}/${rel_path}"
  echo "Signing (${kind}): ${target}"
  sign_with_entitlements "${target}" "${entitlements}"
done < "${MANIFEST}"

echo "Verifying signature..."
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
echo "OK: ${APP_PATH} signed."
