#!/usr/bin/env bash
# tests/cases/codex-classify.sh — bin/koji-codex-classify state machine.
#
# Two modes under test:
#   default (JSON)  — extract a findings array, else quota/timeout/error/empty.
#   --prose         — /duet-plan's codex leg answers in prose ending in a
#                     `VERDICT:` line. Without --prose those critiques get
#                     substring-scanned for 'quota'/'rate limit'/'429' and come
#                     back QUOTA even when the review is perfectly healthy.

CLASSIFY="$KOJI/bin/koji-codex-classify"

# _run <name> <raw-content> <err-content> <exit> [extra args...]
# Writes the three positional fixture files under $TMP/<name>.* and echoes the
# state token. Extra args are passed through verbatim.
_run() {
  local n="$1" raw="$2" err="$3" code="$4"; shift 4
  printf '%s' "$raw" > "$TMP/$n.raw"
  printf '%s' "$err" > "$TMP/$n.err"
  printf '%s' "$code" > "$TMP/$n.exit"
  bash "$CLASSIFY" "$TMP/$n.raw" "$TMP/$n.err" "$TMP/$n.exit" "$@"
}

# --- JSON mode (must be unchanged by the --prose addition) ---

test_json_valid_array_is_ok() {
  local out
  out="$(_run j1 'here you go: [{"severity":"high","category":"correctness"}] done' '' 0 \
          --json-out "$TMP/j1.json")"
  assert_eq OK "$out" "valid array + exit 0"
  assert_file_contains '"severity"' "$TMP/j1.json" "--json-out written"
}

test_json_array_mentioning_rate_limit_is_ok() {
  # Precedence guard: a real review whose TEXT says "rate limit" is still OK.
  local out
  out="$(_run j2 '[{"severity":"low","category":"api","note":"handle rate limit 429"}]' '' 0 \
          --json-out "$TMP/j2.json")"
  assert_eq OK "$out" "array text mentioning rate limit"
  assert_file_contains 'rate limit' "$TMP/j2.json" "array written verbatim"
}

test_json_quota_reply_is_quota() {
  local out
  out="$(_run j3 '' 'Error: usage limit reached, try again in 3h' 1)"
  assert_eq QUOTA "$out" "no array + quota marker on stderr"
}

test_json_timeout_is_timeout() {
  local out
  out="$(_run j4 'partial output, no findings' '' 124)"
  assert_eq TIMEOUT "$out" "no array, exit 124"
}

test_json_error_is_error() {
  local out
  out="$(_run j5 'something went sideways' 'boom' 1)"
  assert_eq ERROR "$out" "no array, exit 1, no markers"
}

test_json_prose_reply_is_empty() {
  local out
  out="$(_run j6 'I reviewed the diff and found nothing worth flagging.' '' 0 \
          --json-out "$TMP/j6.json")"
  assert_eq EMPTY "$out" "prose reply on exit 0 (no --prose)"
  assert_eq '[]' "$(cat "$TMP/j6.json")" "EMPTY writes []"
}

# --- Prose mode ---

test_prose_real_review_is_ok() {
  # The regression that motivated --prose: a genuine codex plan critique that
  # discusses quota handling, ending in VERDICT: DISAGREE.
  local out
  cp "$KOJI/tests/fixtures/codex-prose-review.txt" "$TMP/p1.raw"
  : > "$TMP/p1.err"
  echo 0 > "$TMP/p1.exit"
  out="$(bash "$CLASSIFY" "$TMP/p1.raw" "$TMP/p1.err" "$TMP/p1.exit" --prose)"
  assert_eq OK "$out" "healthy prose review with VERDICT line"
}

test_prose_trap_is_closed_without_the_flag_too() {
  # Same inputs, no --prose. This used to read QUOTA — the false back-off the
  # flag was made for. Since an exit-0 reply's stdout counts toward a quota only
  # when it is shaped like a refusal, a healthy critique that DISCUSSES quotas
  # is EMPTY here (the call site's malformed-reply path), never QUOTA.
  local out
  cp "$KOJI/tests/fixtures/codex-prose-review.txt" "$TMP/p2.raw"
  : > "$TMP/p2.err"
  echo 0 > "$TMP/p2.exit"
  out="$(bash "$CLASSIFY" "$TMP/p2.raw" "$TMP/p2.err" "$TMP/p2.exit")"
  assert_eq EMPTY "$out" "a critique about quotas is not a quota, even without --prose"
}

test_prose_real_quota_still_quota() {
  local out
  out="$(_run p3 '' "You've hit your usage limit. Resets at 4pm." 1 --prose)"
  assert_eq QUOTA "$out" "genuine quota reply in prose mode"
}

test_prose_without_verdict_is_empty() {
  local out
  out="$(_run p4 'I read the plan. It looks broadly fine to me.' '' 0 --prose)"
  assert_eq EMPTY "$out" "prose with no VERDICT line, exit 0"
}

test_prose_verdict_but_nonzero_exit_is_error() {
  # Exit code wins: a non-zero exit is not a healthy review, verdict or not.
  local out
  out="$(_run p5 'Solid plan overall.

VERDICT: AGREE' '' 1 --prose)"
  assert_eq ERROR "$out" "VERDICT present but exit 1"
}

test_prose_ignores_json_out() {
  # --prose is combinable with --json-out; the flag is accepted and ignored.
  local out
  out="$(_run p6 'Looks good.

VERDICT: PARTIAL' '' 0 --json-out "$TMP/p6.json" --prose)"
  assert_eq OK "$out" "--json-out + --prose, flags after positionals"
  if [ -e "$TMP/p6.json" ]; then
    _fail "prose mode must not write --json-out"
  else
    _ok
  fi
}

test_identifier_fragments_are_not_quota() {
  # The scan also reads review TEXT and codex transcripts, so it matches phrases
  # only. A failed run whose output names a RateLimiter class is an ERROR or a
  # TIMEOUT, never a five-hour quota back-off. (agy's own wording is normalized
  # in koji-agy-exec — see agy-dispatch.sh.)
  local out
  out="$(_run idf "at com.example.RateLimiter.acquire; X-RateLimit-Remaining: 0" "" 1)"
  assert_eq ERROR "$out" "identifier fragments on a failed run"
  out="$(_run idt "" "rateLimit middleware stalled" 124)"
  assert_eq TIMEOUT "$out" "a timeout that mentions rateLimit"
}

test_an_array_of_non_objects_is_not_a_review() {
  # "Error [429]: You have hit your usage limit." at exit 0 yields `[429]`. It used
  # to read OK, so a findings/cross/consult site saw a shape mismatch instead of a
  # quota, and the final review degraded instead of waiting.
  local out
  out="$(_run q429 "Error [429]: You have hit your usage limit." "" 0 --json-out "$TMP/q429.json")"
  assert_eq QUOTA "$out" "an exit-0 [429] refusal"
  out="$(_run strs '["no issues found"]' "" 0)"
  assert_eq EMPTY "$out" "an array of strings is not a findings array"
  out="$(_run emptyarr '[]' "" 0 --json-out "$TMP/e.json")"
  assert_eq OK "$out" "[] is still a clean review"
  out="$(_run dictrl '[{"severity":"low","file":"a","line":1,"category":"perf","description":"add a rate limit"}]' "" 0 --json-out "$TMP/d.json")"
  assert_eq OK "$out" "a findings array that mentions rate limits is still OK"
}

test_429_counts_only_as_a_standalone_number() {
  local out
  out="$(_run sz "" "koji-agy-exec: prompt is 4290 bytes" 75)"
  assert_eq ERROR "$out" "a byte count is not an HTTP 429"
  out="$(_run ln "" "fatal: bad object at line 164290" 1)"
  assert_eq ERROR "$out" "neither is a line number"
  out="$(_run st "" "request failed: status 429" 1)"
  assert_eq QUOTA "$out" "a real 429"
}

test_a_standalone_429_survives_a_long_diagnostic() {
  # Under pipefail, `grep -q` in a pipe SIGPIPEd the producer of a long input
  # and the check failed: a real 429 read ERROR.
  local big; big="$(printf 'request failed: status 429\n'; python3 -c 'print("diag line\n" * 20000)')"
  local out; out="$(_run big429 "" "$big" 1)"
  assert_eq QUOTA "$out" "a 429 at the start of a 130 KB diagnostic"
}

test_an_exit0_answer_about_rate_limits_is_malformed_not_quota() {
  local out
  out="$(_run rlp "We should add a rate limit and return 429 on overload." "" 0 --json-out "$TMP/rlp.json")"
  assert_eq EMPTY "$out" "the call site's malformed-reply retry, not a back-off"
  out="$(_run rlpe "We should add a rate limit." "codex: rate limit exceeded" 0)"
  assert_eq QUOTA "$out" "stderr always counts"
  out="$(_run rlp1 "We should add a rate limit." "" 1)"
  assert_eq QUOTA "$out" "a non-zero exit keeps the full scan"
  printf 'Error [429]: You have hit your usage limit.\n' > "$TMP/ref.txt"
  bash "$CLASSIFY" --refusal "$TMP/ref.txt" && _ok || _fail "--refusal: a refusal"
  printf 'Error budgets beat a fixed rate limit.\n' > "$TMP/nref.txt"
  bash "$CLASSIFY" --refusal "$TMP/nref.txt" && _fail "--refusal: a position read as a refusal" || _ok
}
