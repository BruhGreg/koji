#!/usr/bin/env bash
# tests/cases/verdict-consensus.sh — koji-duet-verdict and the consensus helper.
#
# One parser reads every vote: the wrapper's `--expect verdict` check, the
# classifier's --prose mode, and koji-triangulate-review-consensus. These tests
# pin the two ways the old in-file grep auto-locked a plan, and the markdown
# forms reviewers really write.

VERDICT="$KOJI/bin/koji-duet-verdict"
CONSENSUS="$KOJI/bin/koji-triangulate-review-consensus"

_v() {   # _v <text> — the token koji-duet-verdict reads from a file holding <text>
  printf '%s\n' "$1" > "$TMP/v.txt"
  "$VERDICT" "$TMP/v.txt"
}

test_plain_tokens() {
  assert_eq AGREE "$(_v 'VERDICT: AGREE')"
  assert_eq PARTIAL "$(_v 'VERDICT: PARTIAL')"
  assert_eq DISAGREE "$(_v 'verdict: disagree')" "case-folded"
}

test_markdown_forms_are_read() {
  assert_eq AGREE "$(_v '**VERDICT: AGREE**')" "bold line"
  assert_eq AGREE "$(_v '**VERDICT:** AGREE')" "bold label"
  assert_eq DISAGREE "$(_v 'VERDICT: **DISAGREE**: the plan skips X')" "bold token, then a reason"
  assert_eq PARTIAL "$(_v '**VERDICT: PARTIAL**: needs two fixes')" "a reason after the bold close"
  assert_eq AGREE "$(_v '> VERDICT: AGREE')" "quoted"
  assert_eq AGREE "$(_v '- **VERDICT:** AGREE.')" "list item, trailing period"
  assert_eq AGREE "$(_v '## VERDICT: AGREE')" "heading"
}

test_only_exact_tokens_count() {
  assert_eq UNKNOWN "$(_v 'VERDICT: AGREEMENT IS NOT POSSIBLE')" "a word that starts with AGREE is not AGREE"
  assert_eq UNKNOWN "$(_v 'VERDICT: MOSTLY AGREE')"
  assert_eq UNKNOWN "$(_v 'VERDICT:')" "an empty vote"
  assert_eq UNKNOWN "$(_v 'The verdict is AGREE')" "no VERDICT: label"
  assert_eq UNKNOWN "$(_v 'Final VERDICT: AGREE')" "the label must open the line"
}

test_the_last_verdict_line_wins() {
  printf 'VERDICT: AGREE\nOn reflection, one blocker remains.\n**VERDICT: PARTIAL**\n' > "$TMP/v.txt"
  assert_eq PARTIAL "$("$VERDICT" "$TMP/v.txt")"
}

test_a_missing_file_is_unknown() {
  assert_eq UNKNOWN "$("$VERDICT" "$TMP/does-not-exist")"
}

_consensus() {   # _consensus <claude-text> <codex-text>  →  RC, $TMP/c.out
  printf '%s\n' "$1" > "$TMP/c1.txt"; printf '%s\n' "$2" > "$TMP/c2.txt"
  RC=0; "$CONSENSUS" "$TMP/c1.txt" "$TMP/c2.txt" > "$TMP/c.out" 2>&1 || RC=$?
}

test_consensus_locks_only_on_two_exact_agrees() {
  _consensus 'VERDICT: AGREE' '**VERDICT: AGREE**'
  assert_exit 0 "$RC" "two AGREE votes lock"
  assert_file_contains "consensus: both AGREE" "$TMP/c.out"
}

test_codex_probes_never_lock() {
  # Both were reproduced against the old in-file grep: each printed
  # "consensus: both AGREE" and auto-locked the plan.
  _consensus 'VERDICT: AGREEMENT IS NOT POSSIBLE' 'VERDICT: AGREE'
  assert_exit 1 "$RC" "a word that starts with AGREE does not lock"
  _consensus 'VERDICT: AGREE' "$(printf 'VERDICT: AGREE\nVERDICT: PARTIAL')"
  assert_exit 1 "$RC" "a later PARTIAL overrides an earlier AGREE"
  assert_file_contains "codex=PARTIAL" "$TMP/c.out"
}

test_a_missing_vote_never_locks() {
  _consensus 'No verdict line here.' 'VERDICT: AGREE'
  assert_exit 1 "$RC" "no vote"
  assert_file_contains "claude=NONE" "$TMP/c.out"
  RC=0; "$CONSENSUS" "$TMP/c1.txt" "$TMP/nope.txt" > "$TMP/c.out" 2>&1 || RC=$?
  assert_exit 1 "$RC" "a missing file never locks"
}

test_inline_code_forms_are_read() {
  # The prompt templates show the line in backticks; models copy that form.
  assert_eq AGREE "$(_v '`VERDICT: AGREE`')" "the whole line in backticks"
  assert_eq PARTIAL "$(_v 'VERDICT: `PARTIAL`')" "the token in backticks"
  assert_eq DISAGREE "$(_v '`VERDICT:` **DISAGREE**: missing X')" "mixed"
}

test_prose_about_a_vote_is_not_a_vote() {
  assert_eq UNKNOWN "$(_v 'VERDICT: AGREE is not possible until X lands')"
  assert_eq UNKNOWN "$(_v '**VERDICT: AGREE** would be my vote after that change')"
  assert_eq PARTIAL "$(_v 'VERDICT: PARTIAL: needs X')" "a reason after a colon"
  assert_eq DISAGREE "$(_v 'VERDICT: DISAGREE — skips X')" "a reason after a dash"
  assert_eq AGREE "$(_v 'VERDICT: AGREE (minor nits)')" "a reason in brackets"
  _consensus 'VERDICT: AGREE' '**VERDICT: AGREE** would be my vote after that change'
  assert_exit 1 "$RC" "prose about a vote never auto-locks"
}
