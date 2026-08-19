#!/usr/bin/env bash
# Downloads and extracts the pinned Sparkle release into third_party/sparkle/
# (gitignored), the same shape as scripts/fetch-cef.sh.
#
# Two things come out of the archive and both are used:
#   * Sparkle.framework -- embedded into Browser.app (see Sources/App/CMakeLists.txt).
#   * bin/sign_update, bin/generate_keys -- the release-time EdDSA tools that
#     scripts/release.sh and the one-time key generation call (see
#     docs/auto-update.md).
#
# Version is pinned deliberately -- do not "latest"-ify this without updating
# the pin below. Sparkle's own signature-verification format is part of the
# contract with an already-published appcast, so the version that signs a
# release and the version embedded in the app that verifies it must move
# together and knowingly.
set -euo pipefail

SPARKLE_VERSION="2.9.6"
SPARKLE_ARCHIVE_NAME="Sparkle-${SPARKLE_VERSION}.tar.xz"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/${SPARKLE_ARCHIVE_NAME}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARKLE_DIR="${ROOT_DIR}/third_party/sparkle"
DOWNLOAD_DIR="${ROOT_DIR}/third_party/.downloads"
ARCHIVE_PATH="${DOWNLOAD_DIR}/${SPARKLE_ARCHIVE_NAME}"
STAMP_FILE="${SPARKLE_DIR}/.fetched-version"

if [[ -f "${STAMP_FILE}" ]] && [[ "$(cat "${STAMP_FILE}")" == "${SPARKLE_VERSION}" ]] \
   && [[ -d "${SPARKLE_DIR}/Sparkle.framework" ]]; then
  echo "Sparkle ${SPARKLE_VERSION} already fetched at ${SPARKLE_DIR}"
  exit 0
fi

mkdir -p "${DOWNLOAD_DIR}" "${SPARKLE_DIR}"

if [[ ! -f "${ARCHIVE_PATH}" ]]; then
  echo "Downloading ${SPARKLE_ARCHIVE_NAME} (~15MB)..."
  curl --fail --location --retry 5 --retry-delay 5 \
    -o "${ARCHIVE_PATH}" "${SPARKLE_URL}"
else
  echo "Using cached archive at ${ARCHIVE_PATH}"
fi

echo "Extracting..."
rm -rf "${SPARKLE_DIR}/Sparkle.framework" "${SPARKLE_DIR}/bin"
# Only the framework and the release-time tools -- the archive also carries a
# sample app, debug symbols and docs that have no business in a build tree.
# `tar -x` here preserves the framework's Versions/Current symlinks as
# symlinks, which matters: the copy into the bundle (ditto, in
# Sources/App/CMakeLists.txt) then reproduces a well-formed framework rather
# than the broken self-referential links CMake's own copy_directory leaves
# behind on the CEF framework (see scripts/sign.sh's pruning step).
tar -x -f "${ARCHIVE_PATH}" -C "${SPARKLE_DIR}" Sparkle.framework bin

echo "${SPARKLE_VERSION}" > "${STAMP_FILE}"
echo "Sparkle ${SPARKLE_VERSION} extracted to ${SPARKLE_DIR}"
