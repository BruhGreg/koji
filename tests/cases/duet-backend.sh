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

# --- provider contexts: who really filled the outside-voice slot ------------------
test_provider_reads_the_record() {
  printf 'agy xhigh — ok (gemini-4-neon)\nagy: a note\n' > "$TMP/p.rec"
  assert_eq agy "$("$BE" provider "$TMP/p.rec" 2>/dev/null)"
  printf 'codex max — answered after agy: quota' > "$TMP/p.rec"
  assert_eq codex "$("$BE" provider "$TMP/p.rec" 2>/dev/null)" "a last line with no newline still reads"
  printf 'none - — agy: quota; codex: error (exit 1)\n' > "$TMP/p.rec"
  assert_eq none "$("$BE" provider "$TMP/p.rec" 2>/dev/null)"
}

test_provider_with_no_record_is_codex() {
  assert_eq codex "$("$BE" provider "$TMP/no-such.rec" 2>/dev/null)" "a run that started before 0.11.0"
}

test_a_record_that_proves_no_provider_is_none() {
  local t
  for t in '' 'claude x' 'gemini y' '   '; do
    printf '%s\n' "$t" > "$TMP/p.rec"
    assert_eq none "$("$BE" provider "$TMP/p.rec" 2>"$TMP/p.err")" "token [$t]"
    assert_file_contains "treating it as none" "$TMP/p.err" "token [$t] warns"
  done
}

test_b_provider_precedence() {
  local d="$TMP/run-bp"; rm -rf "$d"; mkdir -p "$d"
  printf 'codex|max|max|opus\n' > "$d/duet-setup"
  assert_eq codex "$("$BE" b-provider "$d" 2>/dev/null)" "no record yet"
  printf 'agy xhigh — ok\n' > "$d/codex.provider"
  assert_eq agy "$("$BE" b-provider "$d" 2>/dev/null)" "the record names the CLI"
  touch "$d/codex.unavailable"
  assert_eq none "$("$BE" b-provider "$d" 2>/dev/null)" "a degraded run beats the record"
  rm -f "$d/codex.unavailable"
  printf 'claude|max|max|opus\n' > "$d/duet-setup"
  assert_eq claude "$("$BE" b-provider "$d" 2>/dev/null)" "role claude beats the record"
  touch "$d/codex.unavailable"
  assert_eq none "$("$BE" b-provider "$d" 2>/dev/null)" "a degraded Claude-B run is none too"
}

test_b_provider_with_lost_setup_is_exit_3() {
  local d="$TMP/run-lost" rc=0; rm -rf "$d"; mkdir -p "$d"
  printf 'agy xhigh — ok\n' > "$d/codex.provider"
  "$BE" b-provider "$d" >/dev/null 2>&1 || rc=$?
  assert_exit 3 "$rc" "lost run state is checked FIRST, before the record"
  printf 'bogus\n' > "$d/duet-setup"
  rc=0; "$BE" b-provider "$d" >/dev/null 2>&1 || rc=$?
  assert_exit 3 "$rc" "an invalid setup is lost state too"
}

test_provider_contexts_need_an_argument() {
  local rc=0; "$BE" provider >/dev/null 2>&1 || rc=$?
  assert_exit 2 "$rc" "provider without a record"
  rc=0; "$BE" b-provider >/dev/null 2>&1 || rc=$?
  assert_exit 2 "$rc" "b-provider without a run dir"
}
