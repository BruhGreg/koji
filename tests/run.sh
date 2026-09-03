#!/usr/bin/env bash
# tests/run.sh — fixture runner for koji's bash/python helpers.
#
#   tests/run.sh            # everything
#   tests/run.sh <case>     # one file: tests/cases/<case>.sh
#
# Not wired into `setup` (koji-selfcheck is the install-time lint). Run before a
# release. Each tests/cases/*.sh gets a fresh $TMP and defines test_* functions.
set -uo pipefail

KOJI="$(cd "$(dirname "$0")/.." && pwd)"
export KOJI
cd "$KOJI"

# --- 1. Syntax: every bash-shebang file, one at a time (bash -n a b checks only a). ---
echo "== syntax =="
SYN_FAIL=0
while IFS= read -r f; do
  if ! bash -n "$f" 2>"${TMPDIR:-/tmp}/koji-syn-err"; then
    echo "  bash -n FAILED: $f"; cat "${TMPDIR:-/tmp}/koji-syn-err"; SYN_FAIL=1
  fi
done < <(grep -lE '^#!/usr/bin/env bash|^#!/bin/bash' bin/* setup tests/run.sh tests/lib.sh tests/cases/*.sh 2>/dev/null)
if command -v python3 >/dev/null 2>&1; then
  while IFS= read -r f; do
    python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "$f" || { echo "  python syntax FAILED: $f"; SYN_FAIL=1; }
  done < <(grep -lE '^#!/usr/bin/env python3' bin/* 2>/dev/null)
fi
[ "$SYN_FAIL" = 0 ] && echo "  ok"

# --- 2. Cases ---
TOTAL_PASS=0; TOTAL_FAIL=$SYN_FAIL
for case_file in tests/cases/*.sh; do
  name="$(basename "$case_file" .sh)"
  [ -n "${1:-}" ] && [ "$1" != "$name" ] && continue
  echo "== $name =="
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/koji-test-$name.XXXXXX")"
  export TMP
  # Run each case file in a subshell so a failing `set -e` or cd can't leak.
  (
    set -u
    . "$KOJI/tests/lib.sh"
    . "$case_file"
    for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
      CURRENT_TEST="$t"
      "$t"
    done
    echo "  $PASS passed, $FAIL failed"
    echo "$PASS $FAIL" > "$TMP/.result"
  )
  read -r p f < "$TMP/.result" 2>/dev/null || { p=0; f=1; echo "  case crashed"; }
  TOTAL_PASS=$((TOTAL_PASS+p)); TOTAL_FAIL=$((TOTAL_FAIL+f))
  rm -rf "$TMP"
done

echo "== total: $TOTAL_PASS passed, $TOTAL_FAIL failed =="
[ "$TOTAL_FAIL" = 0 ]
