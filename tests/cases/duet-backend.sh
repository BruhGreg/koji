#!/usr/bin/env bash
# tests/cases/duet-backend.sh — koji-duet-backend's mapping table.
#
# The whole point of the script is that three skills read ONE table, so the
# test is the table: every (context × strategy) cell, spelled out — plus the
# setup-file contract, which is what the skills actually use.

BE="$KOJI/bin/koji-duet-backend"

# Run with an explicit strategy in the environment (no setup file).
_be() { DUET_STRATEGY="$1" "$BE" "$2" 2>/dev/null; }

# Run against a setup file holding the given tuple, with the env unset so the
# file is provably the source.
_bef() {  # _bef <tuple> <context>
  printf '%s\n' "$1" > "$TMP/duet-setup"
  env -u DUET_STRATEGY "$BE" "$2" "$TMP/duet-setup" 2>"$TMP/be.err"
}

test_plan_round_matrix() {
  assert_eq "codex"  "$(_be codex plan-round)"             "plan-round/codex"
  assert_eq "claude" "$(_be claude plan-round)"            "plan-round/claude"
  assert_eq "claude" "$(_be claude-then-codex plan-round)" "plan-round/claude-then-codex"
  assert_eq "both"   "$(_be both plan-round)"              "plan-round/both"
}

test_impl_gate_matrix() {
  assert_eq "codex"  "$(_be codex impl-gate)"             "impl-gate/codex"
  assert_eq "claude" "$(_be claude impl-gate)"            "impl-gate/claude"
  assert_eq "claude" "$(_be claude-then-codex impl-gate)" "impl-gate/claude-then-codex"
  assert_eq "both"   "$(_be both impl-gate)"              "impl-gate/both"
}

# The row that differs: /duet-review is natively two-family, so slot B is codex
# under every strategy but `claude` — never `both`.
test_review_b_matrix() {
  assert_eq "codex"  "$(_be codex review-b)"             "review-b/codex"
  assert_eq "claude" "$(_be claude review-b)"            "review-b/claude"
  assert_eq "codex"  "$(_be claude-then-codex review-b)" "review-b/claude-then-codex"
  assert_eq "codex"  "$(_be both review-b)"              "review-b/both"
}

# An unrecognised env strategy must degrade to codex, never to an empty token.
test_unknown_env_strategy_falls_back_to_codex() {
  assert_eq "codex" "$(_be gemini plan-round)" "unknown/plan-round"
  assert_eq "codex" "$(_be gemini impl-gate)"  "unknown/impl-gate"
  assert_eq "codex" "$(_be gemini review-b)"   "unknown/review-b"
  # The v0.8.0 name is gone; as an env value it is just another unknown.
  assert_eq "codex" "$(_be 'claude-rounds+codex-final' plan-round)" "old name/plan-round"
}

test_no_file_no_env_defaults_to_codex() {
  assert_eq "codex" "$(env -u DUET_STRATEGY "$BE" plan-round 2>/dev/null)" "unset/plan-round"
  assert_eq "codex" "$(env -u DUET_STRATEGY "$BE" review-b 2>/dev/null)"   "unset/review-b"
}

test_setup_file_is_the_source() {
  assert_eq "both"   "$(_bef 'both|max|max|inherit' impl-gate)"                "file both"
  assert_eq "claude" "$(_bef 'claude-then-codex|xhigh|high|opus' plan-round)"  "file hybrid"
  assert_eq "codex"  "$(_bef 'claude-then-codex|xhigh|high|opus' review-b)"    "file hybrid review-b"
  assert_eq "claude" "$(_bef 'claude|xhigh|xhigh|inherit' review-b)"           "file claude review-b"
  assert_eq "both"   "$(_bef ' Both | MAX | max | Inherit ' impl-gate)"         "file normalized"
}

test_setup_file_beats_env() {
  printf '%s\n' 'both|max|max|inherit' > "$TMP/duet-setup"
  assert_eq "both" "$(DUET_STRATEGY=codex "$BE" impl-gate "$TMP/duet-setup" 2>/dev/null)" "file wins over env"
}

test_missing_setup_file_is_lost_state_not_codex() {
  local out rc=0
  out="$(env -u DUET_STRATEGY "$BE" impl-gate "$TMP/nope" 2>"$TMP/be.err")" || rc=$?
  assert_exit 3 "$rc" "missing file exit 3"
  assert_eq "" "$out" "missing file prints no token"
  assert_contains "run state lost" "$(cat "$TMP/be.err")"
}

test_invalid_setup_file_is_lost_state_not_codex() {
  local out rc=0
  out="$(_bef 'gemini|max|max|inherit' impl-gate)" || rc=$?
  assert_exit 3 "$rc" "bad strategy exit 3"
  assert_eq "" "$out" "bad strategy prints no token"
  rc=0; out="$(_bef 'both|max' impl-gate)" || rc=$?
  assert_exit 3 "$rc" "short tuple exit 3"
  rc=0; out="$(_bef '' impl-gate)" || rc=$?
  assert_exit 3 "$rc" "empty file exit 3"
  assert_eq "" "$out"
}

test_missing_context_is_usage_error() {
  local out rc=0
  out="$(DUET_STRATEGY=codex "$BE" 2>/dev/null)" || rc=$?
  assert_exit 2 "$rc" "missing arg"
  assert_eq "" "$out" "missing arg prints no token"
}

test_unknown_context_is_usage_error() {
  local out rc=0
  out="$(DUET_STRATEGY=claude "$BE" review-c 2>/dev/null)" || rc=$?
  assert_exit 2 "$rc" "unknown context"
  assert_eq "" "$out" "unknown context prints no token"
  # Context is checked before the file, so a bad context never reads the file.
  rc=0; out="$(env -u DUET_STRATEGY "$BE" review-c "$TMP/nope" 2>/dev/null)" || rc=$?
  assert_exit 2 "$rc" "unknown context with missing file is still usage"
}

# Callers use this inline; one trailing newline and nothing else on stdout.
test_output_is_one_bare_token() {
  local out
  out="$(_be claude plan-round | wc -l | tr -d ' ')"
  assert_eq "1" "$out" "exactly one output line"
  out="$(_bef 'both|max|max|inherit' impl-gate | wc -l | tr -d ' ')"
  assert_eq "1" "$out" "exactly one output line (file)"
}
