#!/usr/bin/env bash
# tests/cases/duet-backend.sh — koji-duet-backend's mapping table.
#
# The whole point of the script is that three skills read ONE table, so the
# test is the table: every (context × DUET_REVIEWER) cell, spelled out.

BE="$KOJI/bin/koji-duet-backend"

# Run with an explicit reviewer value.
_be() { DUET_REVIEWER="$1" "$BE" "$2" 2>/dev/null; }

# Run with $DUET_REVIEWER removed, in a directory that is not a git repo and
# with the global koji config redirected into $TMP — so the self-sourced
# koji-detect answers from ITS defaults, not from whatever the machine running
# the suite has configured.
_be_unset() {
  local d="$TMP/nocfg"
  mkdir -p "$d"
  ( cd "$d" && env -u DUET_REVIEWER KOJI_STATE_DIR="$TMP/state" "$BE" "$1" 2>/dev/null )
}

test_plan_round_matrix() {
  assert_eq "codex"  "$(_be codex plan-round)"                      "plan-round/codex"
  assert_eq "claude" "$(_be claude plan-round)"                     "plan-round/claude"
  assert_eq "claude" "$(_be 'claude-rounds+codex-final' plan-round)" "plan-round/split"
}

test_impl_gate_matrix() {
  assert_eq "codex"  "$(_be codex impl-gate)"                      "impl-gate/codex"
  assert_eq "claude" "$(_be claude impl-gate)"                     "impl-gate/claude"
  assert_eq "claude" "$(_be 'claude-rounds+codex-final' impl-gate)" "impl-gate/split"
}

# The one row that differs: the final adversarial B-side goes back to codex
# under claude-rounds+codex-final.
test_review_b_matrix() {
  assert_eq "codex"  "$(_be codex review-b)"                      "review-b/codex"
  assert_eq "claude" "$(_be claude review-b)"                     "review-b/claude"
  assert_eq "codex"  "$(_be 'claude-rounds+codex-final' review-b)" "review-b/split"
}

# An unrecognised reviewer must degrade to codex, never to an empty token.
test_unknown_reviewer_falls_back_to_codex() {
  assert_eq "codex" "$(_be gemini plan-round)" "unknown/plan-round"
  assert_eq "codex" "$(_be gemini impl-gate)"  "unknown/impl-gate"
  assert_eq "codex" "$(_be gemini review-b)"   "unknown/review-b"
}

test_unset_reviewer_defaults_to_codex() {
  assert_eq "codex" "$(_be_unset plan-round)" "unset/plan-round"
  assert_eq "codex" "$(_be_unset review-b)"   "unset/review-b"
}

test_missing_context_is_usage_error() {
  local out rc=0
  out="$(DUET_REVIEWER=codex "$BE" 2>/dev/null)" || rc=$?
  assert_exit 2 "$rc" "missing arg"
  assert_eq "" "$out" "missing arg prints no token"
}

test_unknown_context_is_usage_error() {
  local out rc=0
  out="$(DUET_REVIEWER=claude "$BE" review-c 2>/dev/null)" || rc=$?
  assert_exit 2 "$rc" "unknown context"
  assert_eq "" "$out" "unknown context prints no token"
}

# Callers use this inline; one trailing newline and nothing else on stdout.
test_output_is_one_bare_token() {
  local out
  out="$(_be claude plan-round | wc -l | tr -d ' ')"
  assert_eq "1" "$out" "exactly one output line"
}
