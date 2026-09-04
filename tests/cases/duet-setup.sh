#!/usr/bin/env bash
# tests/cases/duet-setup.sh — koji-duet-setup: the tuple's only parser.

DS="$KOJI/bin/koji-duet-setup"

_ds() { "$DS" "$@" 2>"$TMP/ds.err"; }

test_defaults() {
  assert_eq "codex|xhigh|xhigh|inherit" "$(_ds defaults)" "defaults"
}

test_validate_accepts_every_value() {
  assert_eq "both|max|max|inherit"                 "$(_ds validate 'both|max|max|inherit')"
  assert_eq "claude-then-codex|xhigh|high|sonnet"  "$(_ds validate 'claude-then-codex|xhigh|high|sonnet')"
  assert_eq "codex|high|inherit|fable"             "$(_ds validate 'codex|high|inherit|fable')"
  assert_eq "claude|xhigh|xhigh|opus"              "$(_ds validate 'claude|xhigh|xhigh|opus')"
}

test_validate_normalizes_case_and_whitespace() {
  assert_eq "both|max|max|inherit" "$(_ds validate ' Both | MAX |max| Inherit ')" "case + spaces"
}

test_validate_rejects_bad_field_count() {
  local rc=0 out
  out="$(_ds validate 'both|max|max')" || rc=$?
  assert_exit 1 "$rc" "3 fields"
  assert_eq "" "$out" "nothing on stdout"
  assert_contains "expected 4 fields" "$(cat "$TMP/ds.err")"
  rc=0; _ds validate 'both|max|max|inherit|extra' >/dev/null || rc=$?
  assert_exit 1 "$rc" "5 fields"
}

test_validate_rejects_unknown_values() {
  local rc
  rc=0; _ds validate 'gemini|max|max|inherit' >/dev/null || rc=$?
  assert_exit 1 "$rc" "strategy"; assert_contains "unknown strategy" "$(cat "$TMP/ds.err")"
  rc=0; _ds validate 'both|medium|max|inherit' >/dev/null || rc=$?
  assert_exit 1 "$rc" "codex effort"; assert_contains "unknown codex effort" "$(cat "$TMP/ds.err")"
  rc=0; _ds validate 'both|max|low|inherit' >/dev/null || rc=$?
  assert_exit 1 "$rc" "claude effort"
  rc=0; _ds validate 'both|max|max|haiku' >/dev/null || rc=$?
  assert_exit 1 "$rc" "claude model"
  # The old v0.8.0 name is not a strategy any more.
  rc=0; _ds validate 'claude-rounds+codex-final|xhigh|xhigh|inherit' >/dev/null || rc=$?
  assert_exit 1 "$rc" "renamed strategy rejected"
}

test_merge_overlay_wins_per_field() {
  assert_eq "both|xhigh|xhigh|inherit" "$(_ds merge 'codex|xhigh|xhigh|inherit' 'both|||')" "strategy only"
  assert_eq "codex|max|high|sonnet"    "$(_ds merge 'codex|xhigh|xhigh|inherit' '|max|high|sonnet')" "three fields"
  assert_eq "codex|xhigh|xhigh|inherit" "$(_ds merge 'codex|xhigh|xhigh|inherit' '|||')" "empty overlay"
}

test_merge_rejects_invalid_inputs() {
  local rc
  rc=0; _ds merge 'nope|xhigh|xhigh|inherit' '|||' >/dev/null || rc=$?
  assert_exit 1 "$rc" "invalid base"
  rc=0; _ds merge 'codex|xhigh|xhigh|inherit' 'both||' >/dev/null || rc=$?
  assert_exit 1 "$rc" "overlay with 3 fields"
  rc=0; _ds merge 'codex|xhigh|xhigh|inherit' '|banana||' >/dev/null || rc=$?
  assert_exit 1 "$rc" "overlay with bad value"
}

test_summary() {
  assert_eq "both families · codex max · claude max/inherit"                 "$(_ds summary 'both|max|max|inherit')"
  assert_eq "Claude reviews, codex confirms · codex xhigh · claude high/opus" "$(_ds summary 'claude-then-codex|xhigh|high|opus')"
  assert_eq "codex only · codex xhigh · claude xhigh/inherit"                 "$(_ds summary 'codex|xhigh|xhigh|inherit')"
  assert_eq "Claude only · codex high · claude inherit/sonnet"                "$(_ds summary 'claude|high|inherit|sonnet')"
}

test_field() {
  assert_eq "claude-then-codex" "$(_ds field 'claude-then-codex|max|high|opus' 1)"
  assert_eq "max"   "$(_ds field 'claude-then-codex|max|high|opus' 2)"
  assert_eq "high"  "$(_ds field 'claude-then-codex|max|high|opus' 3)"
  assert_eq "opus"  "$(_ds field 'claude-then-codex|max|high|opus' 4)"
  local rc=0; _ds field 'both|max|max|inherit' 5 >/dev/null || rc=$?
  assert_exit 2 "$rc" "index out of range"
}

test_usage_errors() {
  local rc=0; _ds >/dev/null || rc=$?
  assert_exit 2 "$rc" "no subcommand"
  rc=0; _ds validate >/dev/null || rc=$?
  assert_exit 2 "$rc" "validate without tuple"
}

test_output_is_one_line() {
  assert_eq "1" "$(_ds validate 'both|max|max|inherit' | wc -l | tr -d ' ')"
  assert_eq "1" "$(_ds summary 'both|max|max|inherit' | wc -l | tr -d ' ')"
}
