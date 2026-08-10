#!/usr/bin/env bash
# Lists this app's Crashpad minidumps, newest first, and (with --stack) turns
# the newest one into a readable stack trace via lldb (browser-6iv).
#
# usage:
#   ./scripts/crash-dumps.sh [--profiles-root <path>] [--stack] [--copy <dir>]
#
#   --profiles-root  Which instance's dumps to look at. Defaults to the real
#                    daily-driver location, ~/Library/Application Support/
#                    Browser/Profiles -- pass a scratch instance's root to
#                    inspect that instead.
#   --stack          Run `lldb --batch ... -o "bt all"` against the newest
#                    dump and print the result.
#   --copy <dir>     Copy the newest dump (and its printed metadata) into
#                    <dir>, e.g. to attach it to an issue.
#
# Crashpad's database *is* the profiles root -- CEF passes --database=<root_
# cache_path> verbatim -- so dumps land in <profiles-root>/pending (nothing
# uploads them, and Crashpad only promotes a report to completed/ after an
# upload attempt, so pending/ is where they stay). See
# docs/ai-tasks/crash-reporting-notes.md.
set -euo pipefail

PROFILES_ROOT="${HOME}/Library/Application Support/Browser/Profiles"
WANT_STACK=0
COPY_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profiles-root) PROFILES_ROOT="${2:?--profiles-root needs a path}"; shift 2 ;;
    --stack) WANT_STACK=1; shift ;;
    --copy) COPY_DIR="${2:?--copy needs a directory}"; shift 2 ;;
    -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "error: unknown argument $1" >&2; exit 2 ;;
  esac
done

if [[ ! -d "${PROFILES_ROOT}" ]]; then
  echo "error: no such profiles root: ${PROFILES_ROOT}" >&2
  exit 1
fi

DUMPS=()
while IFS= read -r line; do
  [[ -n "${line}" ]] && DUMPS+=("${line}")
done < <(find "${PROFILES_ROOT}/pending" "${PROFILES_ROOT}/completed" "${PROFILES_ROOT}/new" \
           -maxdepth 1 -name '*.dmp' -print 2>/dev/null \
         | while IFS= read -r f; do printf '%s\t%s\n' "$(stat -f %m "$f")" "$f"; done \
         | sort -rn | cut -f2-)

if [[ ${#DUMPS[@]} -eq 0 ]]; then
  echo "No crash dumps under ${PROFILES_ROOT} (pending/, completed/, new/)."
  echo "If this app has never crashed since crash reporting was enabled, that's the expected result."
  exit 0
fi

echo "Crash dumps under ${PROFILES_ROOT} (newest first):"
for dump in "${DUMPS[@]}"; do
  printf '  %s  %6sKB  %s\n' \
    "$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "${dump}")" \
    "$(( $(stat -f %z "${dump}") / 1024 ))" \
    "${dump}"
done

NEWEST="${DUMPS[0]}"
echo
echo "Newest: ${NEWEST}"

# Which process this dump came from, read straight out of the dump's own
# copy of the crashed process's command line and executable path -- enough to
# tell a renderer crash from a browser-process crash without any tooling.
# (Crashpad's product/version/ptype annotations are in there too, but as
# separate key and value string records rather than "key=value" text, so they
# need a real minidump parser rather than strings(1).)
echo "Crashed process (from the dump's own strings):"
strings -a "${NEWEST}" \
  | grep -aoE -- '--type=[a-z-]+|executable_path=[^ ]+' \
  | sort -u | sed 's/^/  /' || true

if [[ -n "${COPY_DIR}" ]]; then
  mkdir -p "${COPY_DIR}"
  cp "${NEWEST}" "${COPY_DIR}/"
  echo
  echo "Copied to ${COPY_DIR}/$(basename "${NEWEST}")"
fi

if [[ "${WANT_STACK}" -eq 1 ]]; then
  echo
  echo "== lldb backtrace (all threads) =="
  # System libraries symbolicate from the dyld shared cache and our own
  # Browser/helper binaries from their (unstripped) symbol tables; the CEF
  # framework's frames come out as ___lldb_unnamed_symbol_* unless the
  # matching release_symbols archive is downloaded -- see
  # docs/ai-tasks/crash-reporting-notes.md.
  lldb --batch \
    -o "target create --core ${NEWEST}" \
    -o "thread list" \
    -o "bt all" 2>&1
fi
