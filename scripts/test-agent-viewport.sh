#!/usr/bin/env bash
# Native agent-window sizing tests. No window is shown and no app is launched.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/browser-viewport-tests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
swiftc "$repo_root/Sources/App/CLI/AgentPageWindowGeometry.swift" \
  "$repo_root/tests/native/AgentPageWindowGeometryTests.swift" -o "$test_directory/tests"
"$test_directory/tests"
