#!/usr/bin/env bash
# Downloads and extracts the pinned CEF macOS arm64 Standard distribution
# into third_party/cef/ (gitignored).
#
# Version is pinned deliberately -- do not "latest"-ify this without updating
# the pin below and re-verifying against docs/research/2026-07-27-cef-swift-architecture.md.
set -euo pipefail

# Pinned 2026-07-27 against https://cef-builds.spotifycdn.com/index.json:
# current stable macOS arm64 "standard" distribution (macosarm64 channel=stable).
CEF_VERSION="150.0.14+g7c1aa68+chromium-150.0.7871.129"
CEF_PLATFORM="macosarm64"
CEF_ARCHIVE_NAME="cef_binary_${CEF_VERSION}_${CEF_PLATFORM}.tar.bz2"
# '+' must be percent-encoded for the CDN URL.
CEF_URL="https://cef-builds.spotifycdn.com/$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${CEF_ARCHIVE_NAME}")"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THIRD_PARTY_DIR="${ROOT_DIR}/third_party/cef"
DOWNLOAD_DIR="${ROOT_DIR}/third_party/.downloads"
ARCHIVE_PATH="${DOWNLOAD_DIR}/${CEF_ARCHIVE_NAME}"
EXTRACTED_DIR="${THIRD_PARTY_DIR}/cef_binary_${CEF_VERSION}_${CEF_PLATFORM}"
STAMP_FILE="${THIRD_PARTY_DIR}/.fetched-version"

if [[ -f "${STAMP_FILE}" ]] && [[ "$(cat "${STAMP_FILE}")" == "${CEF_VERSION}" ]] && [[ -d "${EXTRACTED_DIR}" ]]; then
  echo "CEF ${CEF_VERSION} already fetched at ${EXTRACTED_DIR}"
  exit 0
fi

mkdir -p "${DOWNLOAD_DIR}" "${THIRD_PARTY_DIR}"

if [[ ! -f "${ARCHIVE_PATH}" ]]; then
  echo "Downloading ${CEF_ARCHIVE_NAME} (~285MB compressed)..."
  curl --fail --location --retry 5 --retry-delay 5 --continue-at - \
    -o "${ARCHIVE_PATH}" "${CEF_URL}"
else
  echo "Using cached archive at ${ARCHIVE_PATH}"
fi

echo "Extracting..."
rm -rf "${EXTRACTED_DIR}"
tar -xjf "${ARCHIVE_PATH}" -C "${THIRD_PARTY_DIR}"

echo "${CEF_VERSION}" > "${STAMP_FILE}"
echo "${EXTRACTED_DIR}" > "${THIRD_PARTY_DIR}/.current-path"

echo "CEF ${CEF_VERSION} fetched to ${EXTRACTED_DIR}"
