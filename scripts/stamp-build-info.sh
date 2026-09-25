#!/usr/bin/env bash
# Writes the source tree's git commit, branch and dirty flag into a built
# app's Info.plist (BRWBuildCommit / BRWBuildBranch / BRWBuildDirty), read by
# Sources/App/DevBuildIndicator.swift's banner. Must run BEFORE scripts/sign.sh:
# Info.plist is covered by the bundle's seal, so editing it afterwards
# invalidates the signature.
#
# Stale keys are always removed first, so a tree without git (or a source
# export with no .git) produces a plist without them, never with old values.
#
# usage: ./scripts/stamp-build-info.sh <path/to/Browser.app>
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:?usage: stamp-build-info.sh <path/to/Browser.app>}"
INFO_PLIST="${APP_PATH}/Contents/Info.plist"
PLISTBUDDY=/usr/libexec/PlistBuddy

for key in BRWBuildCommit BRWBuildBranch BRWBuildDirty; do
  "${PLISTBUDDY}" -c "Delete :${key}" "${INFO_PLIST}" 2>/dev/null || true
done

if ! command -v git >/dev/null 2>&1 \
  || ! commit="$(git -C "${ROOT_DIR}" rev-parse --short HEAD 2>/dev/null)"; then
  echo "== Build info: git unavailable, leaving BRWBuild* keys unset =="
  exit 0
fi
branch="$(git -C "${ROOT_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
dirty=false
if [[ -n "$(git -C "${ROOT_DIR}" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
  dirty=true
fi

"${PLISTBUDDY}" -c "Add :BRWBuildCommit string ${commit}" "${INFO_PLIST}"
"${PLISTBUDDY}" -c "Add :BRWBuildBranch string ${branch}" "${INFO_PLIST}"
"${PLISTBUDDY}" -c "Add :BRWBuildDirty bool ${dirty}" "${INFO_PLIST}"
echo "== Build info: ${commit} (${branch})$([[ ${dirty} == true ]] && echo +dirty) =="
