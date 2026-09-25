#!/bin/bash
# Runs the WebKit engine adapter's integration tests: the app's real
# Sources/App/Engine/WebKit*.swift, compiled standalone by
# Packages/WebKitEngineTests and driven against a real WKWebView and a
# loopback HTTP server. No app build, no CEF, no UI -- the web views live in
# an offscreen window that is never shown.
#
#   ./scripts/test-webkit.sh                         # whole suite
#   ./scripts/test-webkit.sh --filter FindTests      # any `swift test` args
#   ./scripts/test-webkit.sh --repeat 10             # flake hunt: N full runs
set -euo pipefail

cd "$(dirname "$0")/../Packages/WebKitEngineTests"

repeat=1
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repeat) repeat="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done

swift build --build-tests
for ((i = 1; i <= repeat; i++)); do
  [[ "$repeat" -gt 1 ]] && echo "=== run $i/$repeat ==="
  swift test --skip-build ${args[@]+"${args[@]}"}
done
