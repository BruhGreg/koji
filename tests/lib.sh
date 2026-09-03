#!/usr/bin/env bash
# tests/lib.sh — tiny assertion helpers for koji helper-script fixtures.
# Sourced by tests/run.sh and every tests/cases/*.sh. No framework.
#
# Each case file defines functions named test_*; run.sh discovers and runs them.
# Use $KOJI (repo root) and $TMP (a fresh scratch dir per case file).

PASS=0; FAIL=0
_fail() { FAIL=$((FAIL+1)); printf '  FAIL %s: %s\n' "${CURRENT_TEST:-?}" "$*" >&2; }
_ok()   { PASS=$((PASS+1)); }

assert_eq() {            # assert_eq <expected> <actual> [label]
  if [ "$1" = "$2" ]; then _ok; else _fail "${3:-} expected [$1] got [$2]"; fi
}
assert_ne() { if [ "$1" != "$2" ]; then _ok; else _fail "${3:-} expected != [$1]"; fi; }
assert_contains() {      # assert_contains <needle> <haystack> [label]
  case "$2" in *"$1"*) _ok ;; *) _fail "${3:-} expected to contain [$1] in: $2" ;; esac
}
assert_not_contains() {
  case "$2" in *"$1"*) _fail "${3:-} expected NOT to contain [$1] in: $2" ;; *) _ok ;; esac
}
assert_exit() {          # assert_exit <expected-code> <actual-code> [label]
  if [ "$1" = "$2" ]; then _ok; else _fail "${3:-} expected exit $1 got $2"; fi
}
assert_file_contains() { # assert_file_contains <needle> <file> [label]
  if grep -qF -- "$1" "$2" 2>/dev/null; then _ok; else _fail "${3:-} $2 lacks [$1]"; fi
}
assert_file_not_contains() {
  if grep -qF -- "$1" "$2" 2>/dev/null; then _fail "${3:-} $2 unexpectedly has [$1]"; else _ok; fi
}
