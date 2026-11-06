#!/bin/bash
# Refreshes the vendored Public Suffix List that CEF passkey requests are
# checked against (PlatformPasskeyBroker). Run it now and then, and commit
# the result with the WebEngineCore tests passing.
set -euo pipefail
cd "$(dirname "$0")/.."
target=Sources/App/Passkeys/public_suffix_list.dat
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
curl -fsSL https://publicsuffix.org/list/public_suffix_list.dat -o "$tmp"
grep -q "===BEGIN PRIVATE DOMAINS===" "$tmp" || { echo "Downloaded list looks wrong" >&2; exit 1; }
mv "$tmp" "$target"
trap - EXIT
(cd Packages/WebEngineCore && swift test --filter 'PublicSuffix|WebAuthn')
echo "Updated $target"
