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

# A secure timestamp is required by notarization (every signature in the
# bundle needs one) but is a harmless no-op for ad-hoc signing (identity "-")
# -- codesign silently skips it since there's no cert chain to timestamp, so
# this is always safe to pass, dev builds included.
sign_with_entitlements() {
  local target="$1"
  local entitlements="$2"
  codesign --force --options runtime --timestamp \
    --sign "${IDENTITY}" \
    --entitlements "${entitlements}" \
    "${target}"
}

FRAMEWORK_DIR="${APP_PATH}/Contents/Frameworks/Chromium Embedded Framework.framework"

if [[ ! -d "${FRAMEWORK_DIR}" ]]; then
  echo "error: CEF framework not found at ${FRAMEWORK_DIR}" >&2
  exit 1
fi

# 1. Innermost first: any Mach-O executable nested inside the framework's
#    Libraries dir (ANGLE/SwANGLE, the CEF sandbox helper, etc). Identified
#    by content (file(1)), not by extension -- CEF has shipped both .dylib
#    and extension-less variants across versions, and guessing wrong means
#    silently skipping one.
#
#    ${FRAMEWORK_DIR}/Libraries is a symlink (-> Versions/Current/Libraries,
#    itself -> Versions/A/Libraries); `find` on a symlink *path* given as
#    the search root does not descend into it without -L. That bug shipped
#    two ad-hoc-signed notarization submissions (rejected: "not signed with
#    a valid Developer ID certificate" on every file under Libraries) before
#    being caught by extracting the submitted zip and inspecting it by hand.
#    Resolving to the real, non-symlink version directory up front avoids
#    both that bug and needing -L (which would also walk right back through
#    a stray self-referential "Libraries" symlink that CMake's framework
#    copy leaves inside Versions/A/Libraries itself).
REAL_VERSION_DIR="$(cd "${FRAMEWORK_DIR}/Versions/Current" && pwd -P)"
LIBRARIES_DIR="${REAL_VERSION_DIR}/Libraries"
if [[ -d "${LIBRARIES_DIR}" ]]; then
  while IFS= read -r -d '' candidate; do
    if file -b "${candidate}" | grep -q "Mach-O"; then
      echo "Signing (lib): ${candidate}"
      codesign --force --options runtime --sign "${IDENTITY}" --timestamp "${candidate}"
    fi
  done < <(find "${LIBRARIES_DIR}" -type f -perm -111 -print0)
fi

# 2. The framework bundle itself.
echo "Signing (framework): ${FRAMEWORK_DIR}"
codesign --force --options runtime --sign "${IDENTITY}" --timestamp "${FRAMEWORK_DIR}"

# 3. Helper app bundles, then the main app last -- exactly the order CMake
#    wrote into the manifest (helpers first, "app|.|..." appended last).
while IFS='|' read -r kind rel_path entitlements; do
  [[ -z "${kind}" ]] && continue
  target="${APP_PATH}/${rel_path}"
  echo "Signing (${kind}): ${target}"
  sign_with_entitlements "${target}" "${entitlements}"
done < "${MANIFEST}"

# No --deep here, deliberately: every nested bundle (framework + helpers) was
# already explicitly signed above in the correct inside-out order, so re-
# verifying is a strict check on the outer app bundle only. --deep re-walks
# nested bundles itself and chokes on the framework's Versions/Current
# symlink ("No such file or directory") even though the signature is valid --
# same class of problem as the "never codesign --deep for CEF bundles" rule
# in AGENTS.md hard constraint #4, just hit during verification instead of
# signing.
echo "Verifying signature..."
codesign --verify --strict --verbose=2 "${APP_PATH}"
echo "OK: ${APP_PATH} signed."
