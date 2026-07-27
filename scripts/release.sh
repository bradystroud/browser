#!/usr/bin/env bash
# End-to-end release pipeline: build -> sign (inside-out, real identity) ->
# verify -> package -> notarize -> staple -> final verify.
#
# Every phase after "build" is individually skippable so this is useful
# before a real Developer ID certificate exists too: with no --identity/
# CODESIGN_IDENTITY it falls back to ad-hoc ("-") and --skip-notarize lets
# the packaging phase be exercised end-to-end without Apple credentials.
#
# See docs/ai-tasks/release-signing-runbook.md for the one-time setup Brady
# needs to do (Developer ID cert + notarytool keychain profile) before this
# can run for real.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"

CONFIG="Release"
IDENTITY="${CODESIGN_IDENTITY:--}"
NOTARY_PROFILE="browser-notary"
OUTPUT_DIR="${ROOT_DIR}/dist"
FORMAT="zip"
DO_BUILD=1
DO_SIGN=1
DO_PACKAGE=1
DO_NOTARIZE=1
DO_STAPLE=1

usage() {
  cat <<'EOF'
Usage: scripts/release.sh [options]

Options:
  --identity <name>        Codesign identity, e.g. "Developer ID Application:
                            Brady Stroud (TEAMID)". Defaults to
                            $CODESIGN_IDENTITY, then ad-hoc ("-").
  --config <Release|Debug> Build configuration (default: Release).
  --format <zip|dmg>       Distributable format (default: zip).
  --notary-profile <name>  xcrun notarytool keychain profile name
                            (default: browser-notary). See the runbook for
                            `notarytool store-credentials` setup.
  --output-dir <dir>       Where to write the distributable (default: dist/).
  --skip-build             Reuse the existing build/ output; don't rebuild.
  --skip-sign              Don't (re-)codesign; assume the app is already
                            signed the way you want it.
  --skip-package           Don't produce a zip/dmg.
  --skip-notarize          Don't submit to Apple notary service (implies
                            --skip-staple, since there's nothing to staple).
  --skip-staple            Sign/package/notarize but don't staple the ticket.
  -h, --help                Show this help.

Examples:
  # Dry run before a Developer ID cert exists: ad-hoc sign, zip, no Apple calls.
  scripts/release.sh --skip-notarize

  # Real release, once the cert + notary profile are set up (see runbook):
  scripts/release.sh --identity "Developer ID Application: Brady Stroud (ABCDE12345)"
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    --notary-profile) NOTARY_PROFILE="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --skip-build) DO_BUILD=0; shift ;;
    --skip-sign) DO_SIGN=0; shift ;;
    --skip-package) DO_PACKAGE=0; shift ;;
    --skip-notarize) DO_NOTARIZE=0; DO_STAPLE=0; shift ;;
    --skip-staple) DO_STAPLE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ "${FORMAT}" != "zip" && "${FORMAT}" != "dmg" ]]; then
  echo "error: --format must be 'zip' or 'dmg', got '${FORMAT}'" >&2
  exit 1
fi

APP_PATH="${BUILD_DIR}/Sources/App/${CONFIG}/Browser.app"
MANIFEST="${BUILD_DIR}/Sources/App/${CONFIG}/.codesign-manifest"

log() { echo; echo "== $* =="; }

# ---------------------------------------------------------------------------
# Phase: build
# ---------------------------------------------------------------------------
if [[ "${DO_BUILD}" -eq 1 ]]; then
  log "Building (${CONFIG})"
  if [[ ! -d "${ROOT_DIR}/third_party/cef" ]] || [[ -z "$(ls -A "${ROOT_DIR}/third_party/cef" 2>/dev/null)" ]]; then
    "${ROOT_DIR}/scripts/fetch-cef.sh"
  fi
  mkdir -p "${BUILD_DIR}"
  cmake -S "${ROOT_DIR}" -B "${BUILD_DIR}" -G Xcode
  cmake --build "${BUILD_DIR}" --config "${CONFIG}" --target Browser
else
  log "Skipping build (--skip-build)"
fi

if [[ ! -d "${APP_PATH}" ]]; then
  echo "error: expected app bundle not found at ${APP_PATH}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Phase: sign
# ---------------------------------------------------------------------------
if [[ "${DO_SIGN}" -eq 1 ]]; then
  log "Signing (identity: ${IDENTITY})"

  if [[ ! -f "${MANIFEST}" ]]; then
    echo "error: manifest ${MANIFEST} not found (did the build phase run?)" >&2
    exit 1
  fi

  # Real-identity release builds should NOT get --use-mock-keychain (that
  # switch exists only to dodge the unautomatable Keychain prompt that
  # ad-hoc signing's unstable Team ID triggers -- see BRWCefApp.mm). Once
  # Sources/Bridge/BRWCefApp.mm is updated to read this key (tracked in
  # beads, linked to browser-k7i), setting it here is what flips real OSCrypt
  # keychain encryption on for signed release builds. Until that bridge
  # change lands this key is inert (ad-hoc dev builds never see it, and
  # nothing reads it yet), so it's safe to always set it here.
  if [[ "${IDENTITY}" != "-" ]]; then
    INFO_PLIST="${APP_PATH}/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Delete :BRWDisableMockKeychain" "${INFO_PLIST}" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :BRWDisableMockKeychain bool true" "${INFO_PLIST}"
  fi

  CODESIGN_IDENTITY="${IDENTITY}" "${ROOT_DIR}/scripts/sign.sh" "${APP_PATH}" "${MANIFEST}"
  # sign.sh already ran `codesign --verify --strict` on the outer app bundle
  # as its last step (see sign.sh for why never --deep -- it chokes on the
  # framework's Versions/Current symlink even on a validly-signed bundle).

  echo "Gatekeeper assessment (expected to fail until notarized+stapled):"
  if spctl --assess --type execute -vv "${APP_PATH}"; then
    echo "  spctl: accepted"
  else
    echo "  spctl: rejected (expected pre-notarization -- ignoring)"
  fi
else
  log "Skipping sign (--skip-sign)"
fi

# ---------------------------------------------------------------------------
# Phase: package (pre-notarization submission artifact)
# ---------------------------------------------------------------------------
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "0.0.0")"
mkdir -p "${OUTPUT_DIR}"
SUBMIT_ZIP="${OUTPUT_DIR}/Browser-${VERSION}-submit.zip"
DMG_PATH="${OUTPUT_DIR}/Browser-${VERSION}.dmg"
FINAL_ZIP="${OUTPUT_DIR}/Browser-${VERSION}.zip"

if [[ "${DO_PACKAGE}" -eq 1 ]]; then
  log "Packaging (${FORMAT})"
  if [[ "${FORMAT}" == "dmg" ]]; then
    rm -f "${DMG_PATH}"
    STAGING_DIR="$(mktemp -d)"
    cp -R "${APP_PATH}" "${STAGING_DIR}/"
    ln -s /Applications "${STAGING_DIR}/Applications"
    hdiutil create -volname "Browser" -srcfolder "${STAGING_DIR}" -ov -format UDZO "${DMG_PATH}"
    rm -rf "${STAGING_DIR}"
    echo "Wrote ${DMG_PATH}"
  else
    rm -f "${SUBMIT_ZIP}"
    ditto -c -k --keepParent "${APP_PATH}" "${SUBMIT_ZIP}"
    echo "Wrote ${SUBMIT_ZIP} (notarization submission artifact)"
  fi
else
  log "Skipping package (--skip-package)"
fi

# ---------------------------------------------------------------------------
# Phase: notarize
# ---------------------------------------------------------------------------
if [[ "${DO_NOTARIZE}" -eq 1 ]]; then
  log "Notarizing (keychain profile: ${NOTARY_PROFILE})"
  SUBMIT_PATH="${SUBMIT_ZIP}"
  [[ "${FORMAT}" == "dmg" ]] && SUBMIT_PATH="${DMG_PATH}"

  if [[ ! -e "${SUBMIT_PATH}" ]]; then
    echo "error: nothing to submit at ${SUBMIT_PATH} (run without --skip-package first)" >&2
    exit 1
  fi

  xcrun notarytool submit "${SUBMIT_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait
else
  log "Skipping notarize (--skip-notarize)"
fi

# ---------------------------------------------------------------------------
# Phase: staple
# ---------------------------------------------------------------------------
if [[ "${DO_STAPLE}" -eq 1 ]]; then
  log "Stapling"
  xcrun stapler staple "${APP_PATH}"

  if [[ "${DO_PACKAGE}" -eq 1 ]]; then
    log "Re-packaging stapled app for distribution"
    if [[ "${FORMAT}" == "dmg" ]]; then
      # The dmg built in the package phase wraps the pre-staple app; staple
      # the container itself so Gatekeeper can verify it offline too, then
      # rebuild it around the now-stapled .app for good measure.
      xcrun stapler staple "${DMG_PATH}" || true
      rm -f "${DMG_PATH}"
      STAGING_DIR="$(mktemp -d)"
      cp -R "${APP_PATH}" "${STAGING_DIR}/"
      ln -s /Applications "${STAGING_DIR}/Applications"
      hdiutil create -volname "Browser" -srcfolder "${STAGING_DIR}" -ov -format UDZO "${DMG_PATH}"
      rm -rf "${STAGING_DIR}"
      xcrun stapler staple "${DMG_PATH}"
      echo "Distributable: ${DMG_PATH}"
    else
      # The zip built for submission wraps the pre-staple app; the staple
      # ticket only exists inside the app bundle now, so re-zip it as the
      # actual distributable. (Submission zip is left in place for reference.)
      rm -f "${FINAL_ZIP}"
      ditto -c -k --keepParent "${APP_PATH}" "${FINAL_ZIP}"
      echo "Distributable: ${FINAL_ZIP}"
    fi
  fi

  log "Final Gatekeeper assessment"
  spctl --assess --type execute -vv "${APP_PATH}"
  echo "OK: notarized and stapled."
else
  log "Skipping staple (--skip-staple)"
  if [[ "${DO_PACKAGE}" -eq 1 ]]; then
    if [[ "${FORMAT}" == "dmg" ]]; then
      echo "Distributable (unstapled): ${DMG_PATH}"
    else
      echo "Distributable (unstapled): ${SUBMIT_ZIP}"
    fi
  fi
fi

log "Done"
