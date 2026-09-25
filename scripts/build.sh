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

# Sparkle is a compile-time dependency now (browser-wc7) -- CMake fails the
# configure step outright without it, so this runs unconditionally. It's a
# no-op once the pinned version is on disk, unlike the CEF fetch above which
# is guarded only because its download is ~285MB.
"${ROOT_DIR}/scripts/fetch-sparkle.sh"

# Two ./scripts/build.sh runs against this same shared build/ dir race on
# Xcode's own build-system database (XCBuildData/build.db) -- not a code
# problem, but "unable to attach DB ... database is locked" reads exactly
# like one, and has repeatedly cost agents real time chasing a phantom break
# (browser-7qw). macOS ships no flock(1) (unlike Linux), so this is a plain
# mkdir-based lock -- mkdir on a not-yet-existing path is atomic on a POSIX
# filesystem, the standard portable substitute. Deliberately scoped to just
# this script's own build/ dir, independent of ${CONFIG}: a Debug build and
# a Release build against the same build/ dir share the same build.db, so
# they'd race just as much as two Debug builds would. scripts/release.sh's
# own build-release/ is a different, already-isolated directory (browser-
# rkn) and is untouched by this lock.
LOCK_DIR="${BUILD_DIR}/.build-lock"
acquire_build_lock() {
  mkdir -p "${BUILD_DIR}"
  local printed_wait_message=0
  while ! mkdir "${LOCK_DIR}" 2>/dev/null; do
    local holder_pid=""
    if [[ -f "${LOCK_DIR}/pid" ]]; then
      holder_pid="$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)"
    fi
    # A killed/crashed build (e.g. -9) never reaches the trap below and
    # would otherwise wedge every future build against this dir forever --
    # reclaim the lock once its recorded holder process is confirmed gone.
    if [[ -n "${holder_pid}" ]] && ! kill -0 "${holder_pid}" 2>/dev/null; then
      echo "== Stale build lock from dead process ${holder_pid} -- reclaiming =="
      rm -rf "${LOCK_DIR}"
      continue
    fi
    if [[ "${printed_wait_message}" -eq 0 ]]; then
      echo "== Waiting for another build to finish (shared ${BUILD_DIR}, held by pid ${holder_pid:-unknown})... =="
      printed_wait_message=1
    fi
    sleep 2
  done
  echo $$ > "${LOCK_DIR}/pid"
  # Released on any exit -- success, error (set -e), or signal -- so a
  # failed or interrupted build never leaves the next one waiting forever.
  trap 'rm -rf "${LOCK_DIR}"' EXIT
}
acquire_build_lock

echo "== Configuring (CMake + Xcode generator) =="
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

# Commit/branch/dirty for the dev-build banner -- before signing, like the
# key above, since Info.plist is inside the seal.
"${ROOT_DIR}/scripts/stamp-build-info.sh" "${APP_PATH}"

# browser-82d: the `browser` CLI (browser-cli/, a standalone SwiftPM
# executable) -- built and dropped
# into the app bundle's Resources so it travels with it, but deliberately
# kept off the app build's critical path: a failure here is a warning, never
# a reason to fail the whole ./scripts/build.sh (nothing about Browser.app
# itself depends on this binary existing). Must happen *before*
# scripts/sign.sh below, not after -- adding a file into an already-signed
# bundle invalidates its resource seal, so this binary needs to already be
# sitting in place before that script's final codesign of the main app
# bundle runs, not layered on top of it afterward.
echo "== Building browser CLI (browser-cli/) =="
if swift build --package-path "${ROOT_DIR}/browser-cli" -c release; then
  CLI_BIN_DIR="${APP_PATH}/Contents/Resources/bin"
  mkdir -p "${CLI_BIN_DIR}"
  cp "${ROOT_DIR}/browser-cli/.build/release/browser" "${CLI_BIN_DIR}/browser"
  # Signed on its own, independent of the app bundle's own inside-out pass
  # below -- this is what lets Brady run it directly (symlinked onto his
  # PATH, outside the app bundle entirely) as a normal signed executable,
  # not just as an inert resource file along for the ride inside the seal.
  codesign --force --options runtime --timestamp --sign "${CODESIGN_IDENTITY:--}" "${CLI_BIN_DIR}/browser"
  echo "== browser CLI built: ${CLI_BIN_DIR}/browser =="
else
  echo "warning: browser CLI build failed -- continuing without it (Browser.app itself is unaffected)" >&2
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

browser CLI (browser-82d) -- put it on your PATH once:
  ln -sf "${APP_PATH}/Contents/Resources/bin/browser" /usr/local/bin/browser
Then, with the app running:
  browser profiles
  browser open https://example.com
  browser route-test https://ssw.com.au --json
EOF
