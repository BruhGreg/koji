#!/usr/bin/env bash
# tests/cases/duet-findings-check.sh — koji-duet-findings-check: a slot file
# must hold a validated array, never a parseable-but-garbage one.

FC="$KOJI/bin/koji-duet-findings-check"

_fc() {  # _fc [--cross|--consult] <json-text> → exit code
  local mode="" body
  case "${1:-}" in --cross|--consult) mode="$1"; shift ;; esac
  body="$1"
  printf '%s' "$body" > "$TMP/in.json"
  local rc=0
  if [ -n "$mode" ]; then "$FC" "$mode" "$TMP/in.json" 2>"$TMP/fc.err" || rc=$?
  else "$FC" "$TMP/in.json" 2>"$TMP/fc.err" || rc=$?; fi
  echo "$rc"
}

test_empty_array_passes_every_mode() {
  assert_eq 0 "$(_fc '[]')" "findings"
  assert_eq 0 "$(_fc --cross '[]')" "cross"
  assert_eq 0 "$(_fc --consult '[]')" "consult"
}

OK='{"fingerprint":"a.py:3:correctness","severity":"high","category":"correctness","file":"a.py","line":3,"description":"off by one","suggested_fix":{"type":"mechanical","scope":"single-file","details":"use <"}}'

test_valid_findings_pass() {
  assert_eq 0 "$(_fc "[$OK]")"
  assert_eq 0 "$(_fc '[{"severity":"low","category":"style","file":"b.py","line":1,"description":"nit"}]')" "suggested_fix optional"
  assert_eq 0 "$(_fc '[{"severity":"medium","category":"scope","file":"src/x.rs","line":0,"description":"overshoot"}]')" "line 0 is an integer"
}

# file and line feed the synthesizer's fingerprint (file:line:category); a
# finding without them would collapse onto every other such finding.
test_findings_without_file_or_line_fail() {
  assert_eq 1 "$(_fc '[{"severity":"medium","category":"scope","line":3,"description":"overshoot"}]')" "file absent"
  assert_eq 1 "$(_fc '[{"severity":"low","category":"style","file":null,"line":3,"description":"nit"}]')" "file null"
  assert_eq 1 "$(_fc '[{"severity":"high","category":"x","file":"a.py","description":"y"}]')" "line absent"
  assert_eq 1 "$(_fc '[{"severity":"high","category":"x","file":"a.py","line":"3","description":"y"}]')" "line as string"
  assert_eq 1 "$(_fc '[{"severity":"high","category":"x","file":"a.py","line":true,"description":"y"}]')" "line as bool"
  assert_contains "line must be an integer" "$(cat "$TMP/fc.err")"
}

test_garbage_arrays_fail() {
  assert_eq 1 "$(_fc '["not","objects"]')" "strings"
  assert_contains "not an object" "$(cat "$TMP/fc.err")"
  assert_eq 1 "$(_fc '[{"category":"x","file":"a","line":1,"description":"y"}]')" "missing severity"
  assert_eq 1 "$(_fc '[{"severity":"critical","category":"x","file":"a","line":1,"description":"y"}]')" "bad severity"
  assert_eq 1 "$(_fc '[{"severity":"high","category":"","file":"a","line":1,"description":"y"}]')" "empty category"
  assert_eq 1 "$(_fc '[{"severity":"high","category":"x","file":7,"line":1,"description":"y"}]')" "file not a string"
  assert_eq 1 "$(_fc '[{"severity":"high","category":"x","file":"a","line":1,"description":"y","suggested_fix":"just fix it"}]')" "suggested_fix not an object"
  assert_eq 1 "$(_fc "[$OK,{\"severity\":\"high\"}]")" "second entry bad"
}

test_not_an_array_fails() {
  assert_eq 1 "$(_fc '{"findings":[]}')" "object"
  assert_contains "not a list" "$(cat "$TMP/fc.err")"
  assert_eq 1 "$(_fc 'I found nothing wrong.')" "prose"
  assert_eq 1 "$(_fc '')" "empty file"
}

test_missing_file_fails() {
  local rc=0; "$FC" "$TMP/does-not-exist.json" 2>/dev/null || rc=$?
  assert_exit 1 "$rc"
}

test_cross_schema() {
  assert_eq 0 "$(_fc --cross '[{"fingerprint":"a.py:3:correctness","verdict":"AGREE-HIGH","rationale":"yes"}]')"
  assert_eq 0 "$(_fc --cross '[{"fingerprint":"f","verdict":"NEEDS-MORE-CONTEXT"}]')"
  assert_eq 1 "$(_fc --cross '[{"fingerprint":"f","verdict":"AGREE"}]')" "plain AGREE is not a label"
  assert_eq 1 "$(_fc --cross '[{"verdict":"DISAGREE"}]')" "no fingerprint"
  assert_eq 1 "$(_fc --cross '[{"severity":"high","category":"x","description":"y"}]')" "findings shape is not a cross verdict"
}

test_consult_schema() {
  assert_eq 0 "$(_fc --consult '[{"fingerprint":"f","verdict":"WITHDRAW","guidance":"was wrong"}]')"
  assert_eq 0 "$(_fc --consult '[{"fingerprint":"f","verdict":"RECONFIRM","guidance":"do X"}]')"
  assert_eq 1 "$(_fc --consult '[{"fingerprint":"f","verdict":"AGREE-HIGH"}]')" "cross label is not a consult verdict"
}

test_usage_errors() {
  local rc=0; "$FC" 2>/dev/null || rc=$?
  assert_exit 2 "$rc" "no file"
  rc=0; "$FC" --cross --consult "$TMP/in.json" 2>/dev/null || rc=$?
  assert_exit 2 "$rc" "two modes"
}
