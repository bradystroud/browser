#!/usr/bin/env bash
# Launches a scratch Browser.app instance from an isolated COPY of the built
# bundle, never from build/Sources/App/<config>/Browser.app directly.
#
# Why: that shared path is also what a concurrent ./scripts/build.sh
# re-signs as its very last step. If a scratch instance is already running
# from that exact path when another build finishes, the kernel's code-
# signing enforcement SIGKILLs it the moment its backing pages are
# rewritten -- no crash report, nothing in Console beyond a bare exit, and
# it has repeatedly been misdiagnosed as flaky host/environment load rather
# than this race (see AGENTS.md). Launching from a private copy removes the
# race entirely instead of trying to detect/avoid it: a later build can
# only ever touch the shared build/ path, never this scratch copy.
#
# usage: ./scripts/launch-scratch.sh <profiles-root> [-- <extra Browser args...>]
#   e.g. ./scripts/launch-scratch.sh /private/tmp/my-test -- --profile default --test-no-activate --show-settings-tab general
#
# Set BROWSER_CONFIG=Debug to copy the Debug build instead of the default
# Release one.
#
# The final launch below is an `exec`, not a backgrounded `&` inside this
# script -- so background *this script's invocation* the usual way
# (`./scripts/launch-scratch.sh ... &`) and `$!` is already the real
# Browser process's PID, exactly like launching the binary directly used to
# be. scripts/shot-window.sh works unchanged against that PID.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${BROWSER_CONFIG:-Release}"
SRC_APP="${ROOT_DIR}/build/Sources/App/${CONFIG}/Browser.app"

PROFILES_ROOT="${1:?usage: launch-scratch.sh <profiles-root> [-- <extra Browser args...>]}"
shift
EXTRA_ARGS=()
if [[ "${1:-}" == "--" ]]; then
  shift
  EXTRA_ARGS=("$@")
fi

[[ -d "${SRC_APP}" ]] || { echo "error: ${SRC_APP} not found -- run ./scripts/build.sh first" >&2; exit 1; }

SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/browser-scratch-app.XXXXXX")"
SCRATCH_APP="${SCRATCH_ROOT}/Browser.app"

# ditto, not cp -R: the standard macOS way to duplicate an app bundle
# without mangling the extended attributes/resource forks its code
# signature depends on.
ditto "${SRC_APP}" "${SCRATCH_APP}"

# Narrower version of the same check the old direct-launch approach needed
# everywhere: this only guards the instant of the ditto above (a build's
# sign.sh could in principle still be mid-write to SRC_APP right as we copy
# it), not this copy's entire running lifetime -- that part of the race is
# gone now that we never launch from SRC_APP itself.
codesign --verify --strict "${SCRATCH_APP}"

mkdir -p "${PROFILES_ROOT}"

echo "Scratch app copy: ${SCRATCH_APP} (rm -rf ${SCRATCH_ROOT} when done)" >&2
exec "${SCRATCH_APP}/Contents/MacOS/Browser" --profiles-root "${PROFILES_ROOT}" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
