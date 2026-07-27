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
#
# Builds into build-release/, never the shared build/ that scripts/build.sh
# and dev agents use (beads browser-rkn: a concurrent `scripts/build.sh` run
# re-signed the shared build/ tree ad-hoc mid-pipeline, corrupting a release
# in progress and shipping an ad-hoc-signed submission to Apple's notary
# service). Isolated directories mean a dev rebuild can never race a release.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build-release"

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
  --skip-build             Reuse the existing build-release/ output; don't
                            rebuild. (This is a dedicated build dir, separate
                            from scripts/build.sh's build/ -- see below.)
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

# Every Mach-O in the bundle, found by content not extension -- same
# reasoning as scripts/sign.sh. A plain (non -L) `find` from the real
# APP_PATH root reaches the CEF framework's nested Libraries/*.dylib via
# their real Versions/A/... path without following any of the framework's
# internal Versions/Current or top-level Libraries symlinks, so nothing
# inside it is double-visited or silently skipped.
all_macho_files() {
  local candidate
  while IFS= read -r -d '' candidate; do
    file -b "${candidate}" | grep -q "Mach-O" && printf '%s\0' "${candidate}"
  done < <(find "${APP_PATH}" -type f -perm -111 -print0)
}

# Gate: every Mach-O must carry the release identity's Developer ID
# authority chain and a secure timestamp before we package/submit anything.
# This is what would have caught the framework's nested-dylib bug (beads
# browser-rkn) before it reached Apple's notary service instead of after.
verify_signing_gate() {
  if [[ "${IDENTITY}" == "-" ]]; then
    echo "Ad-hoc identity -- skipping Developer ID/timestamp gate (expected to fail; this is a dev/test run)."
    return 0
  fi

  log "Verifying every Mach-O carries a Developer ID signature + secure timestamp"
  local offenders=()
  local total=0
  local target info
  while IFS= read -r -d '' target; do
    total=$((total + 1))
    info="$(codesign -dvvv "${target}" 2>&1)"
    if ! grep -q "Authority=Developer ID" <<<"${info}"; then
      offenders+=("${target}: no Developer ID authority")
    elif ! grep -q "^Timestamp=" <<<"${info}"; then
      offenders+=("${target}: no secure timestamp")
    fi
  done < <(all_macho_files)

  if [[ ${#offenders[@]} -gt 0 ]]; then
    echo "error: ${#offenders[@]} of ${total} binaries are not release-ready:" >&2
    printf '  %s\n' "${offenders[@]}" >&2
    exit 1
  fi
  echo "OK: all ${total} Mach-O binaries carry a Developer ID signature + secure timestamp."
}

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

verify_signing_gate

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

  # `notarytool submit --wait` exits 0 even when Apple rejects the
  # submission (status Invalid) -- it only reports the outcome in its
  # output, it doesn't fail the process. Trusting the exit code here is
  # exactly what let two Invalid submissions sail on to stapling and die
  # with "Record not found" while the overall script still reported success
  # (beads browser-rkn). Parse the actual status and fail hard on anything
  # but Accepted, dumping the notary log so the rejection reason is visible
  # without a second manual `notarytool log` round-trip.
  NOTARIZE_LOG="$(mktemp)"
  xcrun notarytool submit "${SUBMIT_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait | tee "${NOTARIZE_LOG}"
  SUBMISSION_ID="$(grep -m1 '^\s*id:' "${NOTARIZE_LOG}" | awk '{print $2}')"
  NOTARIZE_STATUS="$(grep '^\s*status:' "${NOTARIZE_LOG}" | tail -1 | awk '{print $2}')"
  rm -f "${NOTARIZE_LOG}"

  echo "Submission ID: ${SUBMISSION_ID:-<unknown>}"
  echo "Status: ${NOTARIZE_STATUS:-<unknown>}"

  if [[ "${NOTARIZE_STATUS}" != "Accepted" ]]; then
    echo "error: notarization did not succeed (status: ${NOTARIZE_STATUS:-<unknown>}). Full log:" >&2
    if [[ -n "${SUBMISSION_ID:-}" ]]; then
      xcrun notarytool log "${SUBMISSION_ID}" --keychain-profile "${NOTARY_PROFILE}" >&2 || true
    fi
    exit 1
  fi
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
