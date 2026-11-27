#!/usr/bin/env bash
# tests/cases/outside-dispatch.sh — koji-outside-exec, the provider walk.
#
# A fake agy (tests/fixtures/fake-agy) and a fake codex sit on a PATH that has
# no real CLI, so the order, the --expect check, the fallback, the record and
# the failure codes are asserted without spending a call.

OUT_EXEC="$KOJI/bin/koji-outside-exec"
CLASSIFY="$KOJI/bin/koji-codex-classify"

unset CODEX_THREAD_ID CODEX_SANDBOX ANTIGRAVITY_CONVERSATION_ID ANTIGRAVITY_TRAJECTORY_ID
export KOJI_STATE_DIR="$TMP/state"   # the order comes from here, never the user's config

_setup() {   # _setup [agy] [codex] — which fakes are installed
  rm -rf "$TMP/fake" "$TMP/rec" "$TMP/state" "$TMP/run"; mkdir -p "$TMP/fake" "$TMP/rec" "$TMP/state" "$TMP/run"
  local want=" $* "
  case "$want" in *" agy "*) cp "$KOJI/tests/fixtures/fake-agy" "$TMP/fake/agy"; chmod +x "$TMP/fake/agy" ;; esac
  case "$want" in *" codex "*)
    cat > "$TMP/fake/codex" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$TMP/rec/codex.argv"
cat > "$TMP/rec/codex.stdin"
case "\${FAKE_CODEX_MODE:-ok}" in
  ok)      printf '[]\n' ;;
  prose)   printf 'looks good to me\n' ;;
  verdict) printf 'Fine.\nVERDICT: AGREE\n' ;;
  blank)   printf '\n' ;;
  error)   echo "codex: 401 Unauthorized" >&2; exit 1 ;;
  quota)   echo "codex: rate limit exceeded, try again later" >&2; exit 1 ;;
  quota0)  printf 'Error [429]: You have hit your usage limit.\n' ;;
  shortpos) printf 'Use a token bucket per tenant; on overload return 429 with Retry-After, so one client cannot starve the rate limit for the rest.\n' ;;
  rlprose) printf 'We should add a rate limit and return 429 on overload.\n' ;;
  errbudget) printf 'Error budgets beat a fixed rate limit: spend the budget on risky changes, freeze when it runs out, page only on a 429 storm.\n' ;;
  longquota) python3 -c 'print(("Position: rate-limit the quota service per tenant, because one shared quota lets a single tenant starve the rest. " * 8).strip())' ;;
esac
EOF
    chmod +x "$TMP/fake/codex" ;;
  esac
  if [ ! -d "$TMP/repo/.git" ]; then
    mkdir -p "$TMP/repo"
    ( cd "$TMP/repo" && git init -q && printf 'original\n' > existing.txt && git add . \
        && git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -qm init )
  fi
  export FAKE_AGY_DIR="$TMP/rec"
  unset FAKE_AGY_MODE FAKE_AGY_MODEL FAKE_AGY_EFFORTS FAKE_AGY_USAGE FAKE_AGY_LOOKUP_FAIL FAKE_AGY_REPLY FAKE_CODEX_MODE
  PATH_FAKE="$TMP/fake:$(_clean_sys_path)"
  printf 'THE-REVIEW-PROMPT\n' > "$TMP/prompt"
}

_run() {   # _run <expect> [VAR=value ...]  →  RC, $TMP/run/x.{raw,err,provider}
  local expect="$1"; shift
  RC=0
  env "$@" PATH="$PATH_FAKE" "$OUT_EXEC" "${TIMEOUT_S:-30}" xhigh "$TMP/repo" "$TMP/run/x.provider" --expect "$expect" \
    < "$TMP/prompt" > "$TMP/run/x.raw" 2> "$TMP/run/x.err" || RC=$?
  echo "$RC" > "$TMP/run/x.exit"
}
_line1() { head -n1 "$TMP/run/x.provider"; }
_state() { "$CLASSIFY" "$TMP/run/x.raw" "$TMP/run/x.err" "$TMP/run/x.exit" "$@"; }

# --- order and fallback ---------------------------------------------------------
test_agy_answers_and_codex_never_starts() {
  _setup agy codex
  _run findings
  assert_exit 0 "$RC" "agy answered"
  assert_contains "agy xhigh — ok" "$(_line1)" "record names agy"
  if [ -f "$TMP/rec/codex.argv" ]; then _fail "codex was started although agy answered"; else _ok; fi
}

test_a_reply_in_the_wrong_shape_moves_to_codex() {
  # Exit 0 is not enough: agy's polite prose instead of a findings array must
  # reach codex now, not burn the call site's malformed-reply retry on agy.
  _setup agy codex
  _run findings FAKE_AGY_MODE=prose
  assert_exit 0 "$RC" "codex answered"
  assert_eq "[]" "$(cat "$TMP/run/x.raw")" "codex's reply, not agy's"
  assert_contains "codex xhigh — answered after agy: reply did not match --expect findings" "$(_line1)"
  assert_file_contains "THE-REVIEW-PROMPT" "$TMP/rec/codex.stdin" "codex got the same prompt"
}

test_every_agy_failure_falls_back() {
  local m
  for m in empty quota error noresult; do
    _setup agy codex
    _run findings FAKE_AGY_MODE="$m"
    assert_exit 0 "$RC" "agy $m → codex"
    assert_contains "codex xhigh" "$(_line1)" "agy $m: codex recorded"
  done
  _setup agy codex
  TIMEOUT_S=2 _run findings FAKE_AGY_MODE=hang
  assert_exit 0 "$RC" "agy timeout → codex"
}

test_only_the_answering_attempt_reaches_the_call_site() {
  _setup agy codex
  _run findings FAKE_AGY_MODE=quota
  assert_file_not_contains "RESOURCE_EXHAUSTED" "$TMP/run/x.err" "agy's quota text stays out of codex's .err"
  assert_eq OK "$(_state --json-out "$TMP/run/j")" "the answered review classifies OK"
  [ -f "$TMP/run/x.provider.1.agy.err" ] && _ok || _fail "the failed attempt's stderr is kept next to the record"
}

test_order_comes_from_koji_config() {
  _setup agy codex
  printf 'outside_order: codex,agy\n' > "$TMP/state/config.yaml"
  _run findings
  assert_contains "codex xhigh — ok" "$(_line1)" "codex first"
  if [ -f "$TMP/rec/stream.argv" ]; then _fail "agy ran although codex is first and answered"; else _ok; fi
}

test_an_invalid_order_falls_back_to_the_default_with_a_warning() {
  _setup agy codex
  printf 'outside_order: gemini,claude\n' > "$TMP/state/config.yaml"
  _run findings
  assert_contains "agy xhigh — ok" "$(_line1)" "default order"
  assert_file_contains "outside_order 'gemini,claude' is invalid" "$TMP/run/x.err"
  local o; o=$(env PATH="$PATH_FAKE" "$OUT_EXEC" --order 2>/dev/null)
  assert_eq "agy codex" "$o" "--order prints the effective order"
}

test_only_pins_one_provider() {
  _setup agy codex
  RC=0
  env FAKE_AGY_MODE=quota PATH="$PATH_FAKE" "$OUT_EXEC" 30 xhigh "$TMP/repo" "$TMP/run/x.provider" --expect consult --only agy \
    < "$TMP/prompt" > "$TMP/run/x.raw" 2> "$TMP/run/x.err" || RC=$?
  assert_ne 0 "$RC" "the pinned provider failed"
  if [ -f "$TMP/rec/codex.argv" ]; then _fail "--only agy must never fall back to codex (consult ownership)"; else _ok; fi
  assert_contains "none - —" "$(_line1)" "record says nobody answered"
}

# --- every provider failed ------------------------------------------------------------
test_an_earlier_quota_survives_a_later_error() {
  # agy out of quota, codex then fails on auth: the final review must WAIT for
  # agy's window, not degrade on codex's error.
  _setup agy codex
  _run findings FAKE_AGY_MODE=quota FAKE_CODEX_MODE=error
  assert_exit 1 "$RC" "the last attempt's exit code"
  assert_file_contains "koji-outside: agy failed: quota" "$TMP/run/x.err"
  assert_eq QUOTA "$(_state --json-out "$TMP/run/j")" "classifies as QUOTA"
  assert_contains "none - — agy: quota; codex: error (exit 1)" "$(_line1)"
}

test_a_malformed_last_reply_stays_malformed() {
  # codex answered (exit 0) in the wrong shape after an agy quota: the call
  # site's malformed-reply retry handles that — it must not become a QUOTA wait.
  _setup agy codex
  _run findings FAKE_AGY_MODE=quota FAKE_CODEX_MODE=prose
  assert_exit 0 "$RC" "last exit 0 passes through"
  assert_file_not_contains "koji-outside:" "$TMP/run/x.err" "no aggregate line"
  assert_eq EMPTY "$(_state --json-out "$TMP/run/j")" "EMPTY → the call site's MALFORMED path"
}

test_a_blank_prose_reply_is_not_a_position() {
  _setup codex
  _run prose FAKE_CODEX_MODE=blank
  assert_exit 75 "$RC" "prose sites have no malformed retry; blank is no reply"
}

test_verdict_expect_needs_a_verdict_line() {
  _setup agy codex
  _run verdict FAKE_AGY_MODE=prose FAKE_CODEX_MODE=verdict
  assert_exit 0 "$RC" "codex's VERDICT reply"
  assert_contains "codex xhigh — answered after agy" "$(_line1)" "agy's prose without VERDICT moved on"
  _setup agy codex
  _run verdict FAKE_AGY_MODE=verdict
  assert_contains "agy xhigh — ok" "$(_line1)" "agy's VERDICT reply is accepted"
}

# --- front door: 78/79/125 before any provider, 127 when none is installed -------
test_no_provider_installed_is_127() {
  _setup
  _run findings
  assert_exit 127 "$RC" "nothing to dispatch to"
  assert_contains "none - — no outside voice installed" "$(_line1)"
  local rc=0; env PATH="$PATH_FAKE" "$OUT_EXEC" --available >/dev/null 2>&1 || rc=$?
  assert_exit 1 "$rc" "--available fails when none is installed"
}

test_a_harness_marker_is_78_even_with_no_provider() {
  # Harness first: under another agent's harness a 127 would route into Claude
  # substitution — Reviewer A reviewing itself.
  _setup
  _run findings ANTIGRAVITY_CONVERSATION_ID=x
  assert_exit 78 "$RC" "78, not 127"
  _setup agy codex
  _run findings CODEX_SANDBOX=1
  assert_exit 78 "$RC" "78 with providers installed"
  if [ -f "$TMP/rec/codex.argv" ] || [ -f "$TMP/rec/stream.argv" ]; then _fail "a provider was started"; else _ok; fi
}

test_a_broken_block_is_79_even_with_no_provider() {
  _setup
  RC=0; env PATH="$PATH_FAKE" "$OUT_EXEC" "" xhigh "$TMP/repo" "$TMP/run/x.provider" --expect findings < "$TMP/prompt" >/dev/null 2>"$TMP/run/e1" || RC=$?
  assert_exit 79 "$RC" "unrestored TIMEOUT, not 127"
  assert_file_contains 'did not restore $TIMEOUT' "$TMP/run/e1" "79 for the TIMEOUT, not for a missing --expect"
  RC=0; env PATH="$PATH_FAKE" "$OUT_EXEC" 30 xhigh "$TMP/repo" --expect findings < "$TMP/prompt" >/dev/null 2>&1 || RC=$?
  assert_exit 79 "$RC" "a dropped record argument"
  RC=0; env PATH="$PATH_FAKE" "$OUT_EXEC" 30 xhigh "$TMP/repo" "$TMP/nowhere/x.provider" --expect findings < "$TMP/prompt" >/dev/null 2>"$TMP/run/e2" || RC=$?
  assert_exit 79 "$RC" "a record in a directory that does not exist (unrestored RUN_DIR)"
  assert_file_contains "the record's directory" "$TMP/run/e2"
  RC=0; env PATH="$PATH_FAKE" "$OUT_EXEC" 30 xhigh "$TMP/repo" "$TMP/run/x.provider" --expect json < "$TMP/prompt" >/dev/null 2>&1 || RC=$?
  assert_exit 79 "$RC" "an unknown --expect kind"
  RC=0; printf '\n' | env PATH="$PATH_FAKE" "$OUT_EXEC" 30 xhigh "$TMP/repo" "$TMP/run/x.provider" --expect findings >/dev/null 2>"$TMP/run/e3" || RC=$?
  assert_exit 79 "$RC" "an empty prompt"
  assert_file_contains "prompt is empty" "$TMP/run/e3"
  RC=0; env PATH="$PATH_FAKE" "$OUT_EXEC" 30 xhigh "$TMP/repo" "$TMP/run/x.provider" < "$TMP/prompt" >/dev/null 2>"$TMP/run/e4" || RC=$?
  assert_exit 79 "$RC" "a dispatch with no --expect"
  assert_file_contains "--expect <findings|cross|consult|verdict|prose> is required" "$TMP/run/e4"
}

test_a_lost_stdin_redirect_fails_before_any_provider() {
  _setup agy codex
  mkfifo "$TMP/never" 2>/dev/null || true
  exec 9<> "$TMP/never"
  RC=0
  env PATH="$PATH_FAKE" KOJI_BUF_CAP=2 "$OUT_EXEC" 30 xhigh "$TMP/repo" "$TMP/run/x.provider" --expect findings <&9 >/dev/null 2>"$TMP/run/e5" || RC=$?
  exec 9>&-
  assert_exit 79 "$RC" "the OUTER read is capped too"
  assert_file_contains "timed out reading the prompt" "$TMP/run/e5" "79 for the stuck stdin, not for a missing flag"
  if [ -f "$TMP/rec/codex.argv" ] || [ -f "$TMP/rec/stream.argv" ]; then _fail "a provider was started"; else _ok; fi
}

test_an_unusable_tmpdir_degrades() {
  _setup agy codex
  RC=0
  env PATH="$PATH_FAKE" TMPDIR=/nonexistent-koji-outside "$OUT_EXEC" 30 xhigh "$TMP/repo" "$TMP/run/x.provider" --expect findings \
    < "$TMP/prompt" >/dev/null 2>&1 || RC=$?
  assert_exit 125 "$RC" "environment, not caller"
}

# --- record ----------------------------------------------------------------------------
test_notes_go_to_the_record_not_the_err_file() {
  _setup agy codex
  RC=0
  env PATH="$PATH_FAKE" "$OUT_EXEC" 30 max "$TMP/repo" "$TMP/run/x.provider" --expect findings \
    < "$TMP/prompt" > "$TMP/run/x.raw" 2> "$TMP/run/x.err" || RC=$?
  assert_contains "agy xhigh — ok" "$(_line1)" "the clamped effort is the recorded one"
  assert_file_contains "agy: agy runs gemini-4-neon at xhigh — max is not offered" "$TMP/run/x.provider"
  assert_file_not_contains "koji-note" "$TMP/run/x.err" "the call site's .err stays clean"
  assert_file_not_contains "koji-used" "$TMP/run/x.err"
}

test_a_missing_agy_is_skipped_and_noted() {
  _setup codex
  _run findings
  assert_exit 0 "$RC" "codex answered"
  assert_file_contains "agy: not installed — skipped" "$TMP/run/x.provider"
}

test_the_provider_reads_back_render_safe() {
  # Collection sites read the provider with `read -r B _` — never awk '{print $1}',
  # which the skill renderer strips to '{print }'.
  _setup agy codex
  _run findings
  local B=""; read -r B _ < "$TMP/run/x.provider"
  assert_eq agy "$B" "first token is the provider"
}

# --- fix round: artifacts, quota at exit 0, breaker, model --------------------------
test_every_dispatch_keeps_its_own_numbered_artifacts() {
  _setup agy codex
  _run findings FAKE_AGY_MODE=prose
  _run findings FAKE_AGY_MODE=prose
  [ -f "$TMP/run/x.provider.1.agy.out" ] && [ -f "$TMP/run/x.provider.2.agy.out" ] && _ok \
    || _fail "a retry overwrote the first dispatch's artifacts"
  assert_file_contains "Looks fine to me." "$TMP/run/x.provider.1.agy.out" "the unusable reply is kept for diagnosis"
}

test_an_exit0_quota_refusal_is_reported_as_quota() {
  # codex refuses at exit 0 with "Error [429]"; in JSON mode that reads as the
  # array [429]. Verdict sites classify in --prose mode, so it is a quota.
  _setup agy codex
  printf 'outside_order: codex,agy\n' > "$TMP/state/config.yaml"
  _run verdict FAKE_CODEX_MODE=quota0 FAKE_AGY_MODE=error
  assert_contains "codex: quota" "$(_line1)" "the exit-0 refusal is a quota, not a shape mismatch"
  assert_file_contains "koji-outside: codex failed: quota" "$TMP/run/x.err"
}

test_a_short_quota_refusal_is_not_a_prose_position() {
  _setup codex
  _run prose FAKE_CODEX_MODE=quota0
  assert_exit 75 "$RC" "a refusal never becomes a /triangulate position"
  assert_file_contains "koji-outside: codex failed: quota" "$TMP/run/x.err" "the call site can see why"
  _setup codex
  _run prose FAKE_CODEX_MODE=longquota
  assert_exit 0 "$RC" "a real position that discusses quotas is still a position"
}

test_a_provider_that_timed_out_is_skipped_for_the_rest_of_the_run() {
  _setup agy codex
  TIMEOUT_S=2 _run findings FAKE_AGY_MODE=hang
  assert_contains "codex xhigh — answered after agy: timeout" "$(_line1)" "first dispatch: agy hung, codex answered"
  [ -e "$TMP/run/.outside-timeout-agy" ] && _ok || _fail "no breaker after the timeout"
  rm -f "$TMP/rec/stream.argv"
  _run findings FAKE_AGY_MODE=hang
  assert_contains "codex xhigh — ok" "$(_line1)" "the next dispatch goes straight to codex"
  assert_file_contains "agy: timed out earlier in this run — skipped" "$TMP/run/x.provider"
  if [ -f "$TMP/rec/stream.argv" ]; then _fail "agy was tried first again"; else _ok; fi
  RC=0
  env PATH="$PATH_FAKE" "$OUT_EXEC" 30 xhigh "$TMP/repo" "$TMP/run/x.provider" --expect findings --only agy \
    < "$TMP/prompt" > "$TMP/run/x.raw" 2> "$TMP/run/x.err" || RC=$?
  assert_exit 0 "$RC" "--only keeps its provider, breaker or not"
  if [ -e "$TMP/run/.outside-timeout-agy" ]; then _fail "a usable reply did not clear the breaker"; else _ok; fi
}

test_the_record_names_the_model_that_answered() {
  _setup agy codex
  _run findings
  assert_contains "agy xhigh — ok (gemini-4-neon)" "$(_line1)"
}

test_a_short_position_about_rate_limits_stays_a_position() {
  # Short and full of quota words, but not shaped like a refusal: a real
  # /triangulate position must never be dropped as a quota.
  _setup codex
  _run prose FAKE_CODEX_MODE=shortpos
  assert_exit 0 "$RC" "the position is usable"
  assert_file_contains "token bucket" "$TMP/run/x.raw"
}

test_preflight_names_the_agy_bypass_state() {
  _setup agy codex
  local err
  err=$(env PATH="$PATH_FAKE" "$KOJI/bin/koji-outside-preflight" 2>&1 >/dev/null)
  assert_contains "agy bypass: off" "$err" "off by default, and the line says how to change it"
  assert_contains "koji-config set agy_bypass yes" "$err"
  printf 'agy_bypass: yes\n' > "$TMP/state/config.yaml"
  err=$(env PATH="$PATH_FAKE" "$KOJI/bin/koji-outside-preflight" 2>&1 >/dev/null)
  assert_contains "agy bypass: on" "$err"
  _setup codex
  err=$(env PATH="$PATH_FAKE" "$KOJI/bin/koji-outside-preflight" 2>&1 >/dev/null)
  assert_not_contains "agy bypass" "$err" "no agy installed, no agy line"
}

test_without_bypass_agy_answers_a_read_only_review() {
  _setup agy codex
  _run findings FAKE_AGY_MODE=readstep
  assert_contains "agy xhigh — ok" "$(_line1)" "agy answered without bypass"
  assert_file_contains "agy: no bypass (koji-config agy_bypass is not yes)" "$TMP/run/x.provider"
}

test_without_bypass_a_write_tool_moves_to_codex() {
  _setup agy codex
  _run findings FAKE_AGY_MODE=toolstep
  assert_contains "codex xhigh — answered after agy" "$(_line1)" "the discarded agy reply moved the call to codex"
  assert_file_contains "agy: ⚠ agy used run_command without bypass" "$TMP/run/x.provider"
}

test_a_breaker_skip_with_nothing_left_is_a_timeout() {
  # The hung provider is skipped, not re-run for its full deadline: with no
  # other provider left the call site gets a TIMEOUT at once.
  _setup agy
  TIMEOUT_S=2 _run findings FAKE_AGY_MODE=hang
  assert_exit 124 "$RC" "the first dispatch timed out"
  local t0 t1; t0=$(date +%s)
  _run findings FAKE_AGY_MODE=hang
  t1=$(date +%s)
  assert_exit 124 "$RC" "skipped, so still a timeout"
  [ $((t1 - t0)) -lt 5 ] && _ok || _fail "the skipped provider was run again ($((t1 - t0)) s)"
  assert_contains "none - — skipped: agy timed out earlier in this run" "$(_line1)"
  assert_eq TIMEOUT "$(_state --json-out "$TMP/run/j")" "classifies as TIMEOUT"
}

test_a_wrong_shape_reply_about_rate_limits_is_not_a_quota() {
  # An exit-0 answer in the wrong shape that DISCUSSES rate limits must not
  # turn a later provider's error into a five-hour quota back-off.
  _setup agy codex
  _run findings FAKE_AGY_REPLY='We should add a rate limit and return 429 on overload.' FAKE_CODEX_MODE=error
  assert_contains "agy: reply did not match --expect findings" "$(_line1)"
  assert_eq ERROR "$(_state --json-out "$TMP/run/j")" "ERROR, not QUOTA"
}

test_a_short_position_starting_with_error_is_a_position() {
  _setup codex
  _run prose FAKE_CODEX_MODE=errbudget
  assert_exit 0 "$RC" "'Error budgets …' is a position, not a refusal"
}

test_an_order_with_a_stray_token_keeps_the_valid_ones() {
  _setup agy codex
  printf 'outside_order: codex,gemini\n' > "$TMP/state/config.yaml"
  local o; o=$(env PATH="$PATH_FAKE" "$OUT_EXEC" --order 2>"$TMP/run/o.err")
  assert_eq "codex" "$o" "the valid token stays; agy is not added back"
  assert_file_contains "ignoring 'gemini'" "$TMP/run/o.err"
  printf 'outside_order: codex → agy\n' > "$TMP/state/config.yaml"
  o=$(env PATH="$PATH_FAKE" "$OUT_EXEC" --order 2>/dev/null)
  assert_eq "codex agy" "$o" "the preflight's own display form"
}

test_an_attempt_writes_straight_into_its_artifacts() {
  _setup agy codex
  _run findings FAKE_AGY_MODE=prose
  assert_file_contains "Looks fine to me." "$TMP/run/x.provider.1.agy.out"
  assert_file_contains "koji-used:" "$TMP/run/x.provider.1.agy.err" "the raw stderr, notes included"
}

test_a_sole_provider_answer_about_rate_limits_is_not_a_quota_at_the_call_site() {
  # The wrapper hands an exit-0 wrong-shape reply back unchanged; the call
  # site's classification must read it as malformed (EMPTY), not as QUOTA.
  _setup codex
  _run findings FAKE_CODEX_MODE=rlprose
  assert_exit 0 "$RC" "the last attempt's exit 0 passes through"
  assert_eq EMPTY "$(_state --json-out "$TMP/run/j")" "EMPTY → the malformed-reply retry"
}
