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

# 0. Prune broken symlinks CMake's framework copy leaves behind before any
#    signing happens. It creates the top-level framework symlinks a second
#    time *inside* the versioned directories, where their targets don't
#    resolve: "Versions/A/A -> A" (self-referential, ELOOP),
#    "Versions/A/Resources/Resources -> Versions/A/Resources" and the same
#    for Libraries. The pristine CEF distribution has no symlinks at all --
#    these are entirely our copy step's doing.
#
#    They must go, and not just for tidiness: `codesign --verify --strict`
#    passes with them present, but **Gatekeeper does not**. `spctl --assess`
#    reports "rejected (invalid destination for symbolic link in bundle)" on
#    an otherwise correctly Developer-ID-signed, notarized and stapled app.
#    That never bites a locally built or `scripts/install.sh`-installed copy
#    (no quarantine flag, so Gatekeeper never assesses it) -- it bites only
#    the *downloaded* copy, i.e. every real user, and Apple's own reviewer.
#    Confirmed by assessing a fully notarized 0.1.0 build before this fix.
while IFS= read -r -d '' stray; do
  echo "Pruning broken symlink: ${stray}"
  rm -f "${stray}"
done < <(find "${FRAMEWORK_DIR}" -type l ! -exec test -e {} \; -print0)

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

# 2b. Sparkle.framework (browser-wc7), if the bundle carries one. Signed on
#     the same inside-out principle as the CEF framework above, but the
#     nesting is deeper: Sparkle ships two XPC services, an Updater.app and a
#     standalone Autoupdate tool inside its own version directory, and every
#     one of them is separately sealed code that codesign will not reach on
#     its own. Order is innermost-outward, exactly as Sparkle's own signing
#     documentation prescribes; the framework itself must come last or its
#     seal covers signatures that are about to be replaced.
#
#     No entitlements on any of them: those are only needed by a sandboxed
#     host app, and this app is never sandboxed (AGENTS.md -- App Sandbox
#     breaks default-browser registration).
#
#     Unlike the CEF framework there is no broken-symlink pruning here: the
#     bundle copy is a `ditto` (see Sources/App/CMakeLists.txt), which
#     reproduces the vendor framework's symlinks faithfully instead of
#     re-creating them wrongly the way CMake's copy_directory does.
SPARKLE_FRAMEWORK_DIR="${APP_PATH}/Contents/Frameworks/Sparkle.framework"
if [[ -d "${SPARKLE_FRAMEWORK_DIR}" ]]; then
  SPARKLE_VERSION_DIR="$(cd "${SPARKLE_FRAMEWORK_DIR}/Versions/Current" && pwd -P)"
  for sparkle_nested in \
      "${SPARKLE_VERSION_DIR}/XPCServices/Downloader.xpc" \
      "${SPARKLE_VERSION_DIR}/XPCServices/Installer.xpc" \
      "${SPARKLE_VERSION_DIR}/Updater.app" \
      "${SPARKLE_VERSION_DIR}/Autoupdate"; do
    [[ -e "${sparkle_nested}" ]] || continue
    echo "Signing (sparkle): ${sparkle_nested}"
    codesign --force --options runtime --sign "${IDENTITY}" --timestamp "${sparkle_nested}"
  done
  echo "Signing (framework): ${SPARKLE_FRAMEWORK_DIR}"
  codesign --force --options runtime --sign "${IDENTITY}" --timestamp "${SPARKLE_FRAMEWORK_DIR}"
fi

# 2c. The Developer ID provisioning profile that authorizes Apple's
#     restricted com.apple.developer.web-browser.public-key-credential
#     entitlement (Touch ID / iCloud Keychain passkeys). A signature that
#     claims a restricted entitlement without an embedded profile allowing
#     it is killed by the kernel at launch, so the profile and the
#     entitlements it grants are always added together or not at all.
#
#     The profile lives outside this public repo. Its restricted keys are
#     read from the profile itself rather than written into
#     entitlements/browser.entitlements, which keeps the team ID out of the
#     repo and keeps ad-hoc builds (which can never carry a profile)
#     launchable.
PROFILE_PATH="${BRW_PROVISIONING_PROFILE:-${HOME}/.config/browser/Browser.provisionprofile}"
EMBEDDED_PROFILE="${APP_PATH}/Contents/embedded.provisionprofile"
APP_ENTITLEMENTS_OVERRIDE=""
rm -f "${EMBEDDED_PROFILE}"
if [[ "${IDENTITY}" != "-" && -f "${PROFILE_PATH}" ]]; then
  PROFILE_WORK_DIR="$(mktemp -d)"
  trap 'rm -rf "${PROFILE_WORK_DIR}"' EXIT
  PROFILE_PLIST="${PROFILE_WORK_DIR}/profile.plist"
  security cms -D -i "${PROFILE_PATH}" > "${PROFILE_PLIST}"
  profile_get() { /usr/libexec/PlistBuddy -c "Print :$1" "${PROFILE_PLIST}"; }

  PROFILE_TEAM="$(profile_get "Entitlements:com.apple.developer.team-identifier")"
  if [[ "${IDENTITY}" != *"(${PROFILE_TEAM})"* ]]; then
    echo "error: provisioning profile ${PROFILE_PATH} is for team ${PROFILE_TEAM}, but the signing identity is '${IDENTITY}'" >&2
    exit 1
  fi

  echo "Embedding provisioning profile: ${PROFILE_PATH}"
  cp "${PROFILE_PATH}" "${EMBEDDED_PROFILE}"
  APP_ENTITLEMENTS_OVERRIDE="${PROFILE_WORK_DIR}/browser.entitlements"
elif [[ "${BRW_REQUIRE_PROVISIONING_PROFILE:-0}" == "1" ]]; then
  echo "error: no provisioning profile at ${PROFILE_PATH} (or ad-hoc identity) -- this build would ship without Touch ID / iCloud Keychain passkeys" >&2
  exit 1
elif [[ "${IDENTITY}" != "-" ]]; then
  echo "warning: no provisioning profile at ${PROFILE_PATH} -- signing without the passkey entitlement" >&2
fi

# 3. Helper app bundles, then the main app last -- exactly the order CMake
#    wrote into the manifest (helpers first, "app|.|..." appended last).
while IFS='|' read -r kind rel_path entitlements; do
  [[ -z "${kind}" ]] && continue
  target="${APP_PATH}/${rel_path}"
  if [[ "${kind}" == "app" && -n "${APP_ENTITLEMENTS_OVERRIDE}" ]]; then
    cp "${entitlements}" "${APP_ENTITLEMENTS_OVERRIDE}"
    for key in com.apple.application-identifier com.apple.developer.team-identifier; do
      /usr/libexec/PlistBuddy -c "Add :${key} string $(profile_get "Entitlements:${key}")" "${APP_ENTITLEMENTS_OVERRIDE}"
    done
    /usr/libexec/PlistBuddy -c "Add :com.apple.developer.web-browser.public-key-credential bool $(profile_get "Entitlements:com.apple.developer.web-browser.public-key-credential")" "${APP_ENTITLEMENTS_OVERRIDE}"
    entitlements="${APP_ENTITLEMENTS_OVERRIDE}"
  fi
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
