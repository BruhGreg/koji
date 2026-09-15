#!/usr/bin/env bash
# tests/cases/koji-timeout.sh — the deadline supervisor.
#
# The FALLBACK is the thing under test. Every case that matters runs with PATH
# stripped of gtimeout and timeout, because the bugs this script exists to avoid
# all live there: a ported implementation lost stdin entirely, never enforced
# its deadline against a TERM-handling child, and left descendants running.
# `sleep` and `true` alone catch none of it.

KT="$KOJI/bin/koji-timeout"
NOBIN="$TMP/nobin"

_setup_nobin() {   # a PATH with the utilities the fallback needs, minus both timeout binaries
  mkdir -p "$NOBIN"
  local b p
  for b in bash sh cat sleep head wc printf mktemp rm grep; do
    p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$NOBIN/$b"
  done
}

_setup_nobin        # once at source time: run.sh sources this file before running test_*

_fb() {            # run koji-timeout with the fallback forced
  env PATH="$NOBIN" "$KT" "$@"
}

# --- argument validation ------------------------------------------------------
# An empty duration is the fresh-shell failure mode: a dispatch block that never
# restored $TIMEOUT. gtimeout answers 125 in ~20ms and the run reads it as a
# reviewer error, so this must refuse loudly instead.
test_refuses_bad_duration() {
  local rc=0; "$KT" "" true 2>/dev/null || rc=$?
  assert_exit 2 "$rc" "empty duration"
  rc=0; "$KT" 30s true 2>/dev/null || rc=$?
  assert_exit 2 "$rc" "non-numeric duration"
  rc=0; "$KT" 0 true 2>/dev/null || rc=$?
  assert_exit 2 "$rc" "zero duration"
  rc=0; "$KT" 5 2>/dev/null || rc=$?
  assert_exit 2 "$rc" "no command"
}

test_refuses_unusable_tmpdir() {
  local rc=0
  env TMPDIR=/nonexistent-koji-timeout-test "$KT" 5 true 2>/dev/null || rc=$?
  # 125, the code timeout(1) uses for "the supervisor itself failed" — NOT 2.
  # 2 means the caller passed something wrong, and koji-codex-exec's callers
  # treat a caller error as terminal; an unusable temp dir must stay a normal
  # degradable failure instead of hard-stopping an unattended run.
  assert_exit 125 "$rc" "supervisor cannot start -> 125, never a false success"
}

test_supervisor_failures_are_prefixed_for_wraps_discriminator() {
  # wrap's commit gate tells "the supervisor could not start" from "the gate
  # itself exited 125" (docker and git bisect both do) by looking for a
  # koji-timeout:-prefixed line in the gate log. That only works if EVERY
  # self-diagnostic carries the prefix — the mktemp branch once did not, which
  # broke the discriminator for the most likely failure of all.
  local out
  out=$(env TMPDIR=/nonexistent-koji-timeout-test "$KT" 5 /bin/echo hi 2>&1 >/dev/null)
  assert_contains "koji-timeout:" "$out" "the 125 path identifies itself"
}

test_caller_errors_and_supervisor_errors_are_distinct() {
  local rc=0; "$KT" "" true 2>/dev/null || rc=$?
  assert_exit 2 "$rc" "bad duration is the caller's fault"
  rc=0; env TMPDIR=/nonexistent-koji-timeout-test "$KT" 5 true 2>/dev/null || rc=$?
  assert_exit 125 "$rc" "unusable TMPDIR is the supervisor's"
}

# --- stdin --------------------------------------------------------------------
# A backgrounded command gets its stdin from /dev/null unless job control is on.
# koji feeds every codex prompt on stdin, so losing it means silently reviewing
# nothing. Size matters too: the whole point of stdin is escaping the argv limit.
test_fallback_delivers_stdin() {
  assert_eq "hello" "$(printf 'hello' | _fb 10 cat)" "small stdin"
  printf 'x%.0s' $(seq 1 200000) > "$TMP/big.txt"
  assert_eq "200000" "$(_fb 20 cat < "$TMP/big.txt" | wc -c | tr -d ' ')" "200KB stdin"
}

# --- deadline enforcement -----------------------------------------------------
test_fallback_deadline_term_graceful() {
  cat > "$TMP/graceful.sh" <<'EOF'
#!/usr/bin/env bash
trap 'exit 0' TERM
sleep 30 & wait
EOF
  chmod +x "$TMP/graceful.sh"
  local rc=0
  _fb 2 "$NOBIN/bash" "$TMP/graceful.sh" 2>/dev/null || rc=$?
  # A child that handles TERM and exits 0 must still report 124. Inferring the
  # deadline from the exit status reports 0 here, and a truncated reply then
  # reads as a clean answer.
  assert_exit 124 "$rc" "TERM-graceful child"
}

test_fallback_deadline_term_ignored() {
  cat > "$TMP/stubborn.sh" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
sleep 30 & wait
EOF
  chmod +x "$TMP/stubborn.sh"
  local rc=0
  _fb 2 "$NOBIN/bash" "$TMP/stubborn.sh" 2>/dev/null || rc=$?
  assert_exit 124 "$rc" "TERM-ignoring child escalates to KILL"
}

test_fast_success_is_never_a_timeout() {
  # Guards a regression that a clock-based deadline check introduced: SECONDS
  # advances on wall-clock second boundaries, so `SECONDS >= DUR` could be true
  # a third of a second in and discard a good reply. Staggered starts land these
  # runs on both sides of a boundary.
  local i bad=0 rc
  for i in 1 2 3 4 5 6; do
    rc=0; _fb 1 "$NOBIN/bash" -c 'sleep 0.30; printf "[]\n"' >/dev/null 2>&1 || rc=$?
    [ "$rc" = 0 ] || bad=$((bad+1))
    env PATH="$NOBIN" sleep 0.17
  done
  assert_eq "0" "$bad" "fast successes reported as timeouts"
}

# --- status passthrough -------------------------------------------------------
test_passes_through_status() {
  local rc=0; _fb 10 "$NOBIN/bash" -c 'exit 0' || rc=$?
  assert_exit 0 "$rc" "success"
  rc=0; _fb 10 "$NOBIN/bash" -c 'exit 7' || rc=$?
  assert_exit 7 "$rc" "nonzero"
  # 137 is what a KILL escalation looks like, so a blanket 137->124 mapping
  # would call this command's own status a deadline.
  rc=0; _fb 10 "$NOBIN/bash" -c 'exit 137' || rc=$?
  assert_exit 137 "$rc" "self-inflicted 137 is not a deadline"
}

test_stray_usr1_is_not_a_deadline() {
  # A command that signals its parent must not fabricate a timeout, and must not
  # kill the wrapper either (USR1 defaults to terminate -> 158).
  local rc=0
  _fb 9 "$NOBIN/bash" -c 'kill -USR1 "$PPID"; sleep 0.1; exit 7' 2>/dev/null || rc=$?
  assert_exit 7 "$rc" "child USR1 keeps the child's status"
}

# --- process hygiene ----------------------------------------------------------
test_descendants_never_outlive_the_wrapper() {
  local tag="koji-timeout-test-$$"
  cat > "$TMP/leaky.sh" <<EOF
#!/usr/bin/env bash
( trap '' TERM; exec -a $tag sleep 25 ) &
trap 'exit 0' TERM
sleep 25 & wait
EOF
  chmod +x "$TMP/leaky.sh"
  _fb 2 "$NOBIN/bash" "$TMP/leaky.sh" >/dev/null 2>&1
  sleep 1
  # The parent exits cleanly on TERM while the descendant ignores it. Retiring
  # the watchdog as soon as the leader exits cancels the pending KILL and leaves
  # that descendant running — so the sweep is unconditional.
  assert_eq "0" "$(pgrep -f "$tag" 2>/dev/null | wc -l | tr -d ' ')" "surviving descendants"
  pkill -f "$tag" 2>/dev/null
}

test_cancelling_the_wrapper_kills_the_command() {
  local tag="koji-timeout-cancel-$$"
  # Launch the wrapper directly, not inside a subshell: $! must be koji-timeout's
  # own pid, or the TERM below never reaches it.
  env PATH="$NOBIN" "$KT" 60 "$NOBIN/bash" -c "exec -a $tag sleep 40" 2>/dev/null &
  local w=$!
  sleep 1
  kill -TERM "$w" 2>/dev/null
  wait "$w" 2>/dev/null
  sleep 2
  # A cancelled 30-minute review must stop spending quota, not detach from it.
  assert_eq "0" "$(pgrep -f "$tag" 2>/dev/null | wc -l | tr -d ' ')" "orphans after cancel"
  pkill -f "$tag" 2>/dev/null
}

test_lost_marker_still_reports_the_deadline() {
  mkdir -p "$TMP/t15"
  cat > "$TMP/graceful2.sh" <<'EOF'
#!/usr/bin/env bash
trap 'exit 0' TERM
sleep 30 & wait
EOF
  chmod +x "$TMP/graceful2.sh"
  env PATH="$NOBIN" TMPDIR="$TMP/t15" "$KT" 3 "$NOBIN/bash" "$TMP/graceful2.sh" 2>/dev/null &
  local w=$!
  sleep 1
  rm -rf "$TMP"/t15/koji-timeout.*
  local rc=0; wait "$w" || rc=$?
  # The marker is created up front and deleted at the deadline, so its absence
  # means "fired". A temp directory that disappears mid-run therefore fails
  # closed, as a timeout, rather than reporting a clean exit.
  assert_exit 124 "$rc" "marker destroyed mid-run"
}

# --- real binary --------------------------------------------------------------
test_real_binary_path_agrees_with_the_fallback() {
  if ! command -v gtimeout >/dev/null 2>&1 && ! command -v timeout >/dev/null 2>&1; then
    _ok; return 0   # nothing to compare against on this machine
  fi
  cat > "$TMP/stubborn2.sh" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
sleep 30 & wait
EOF
  chmod +x "$TMP/stubborn2.sh"
  local rc=0
  "$KT" 2 "$TMP/stubborn2.sh" 2>/dev/null || rc=$?
  # gtimeout reports 137 once -k escalates; both paths must agree that this is a
  # deadline, or the same run gets classified two different ways.
  assert_exit 124 "$rc" "real-binary deadline"
  rc=0; "$KT" 10 bash -c 'exit 7' || rc=$?
  assert_exit 7 "$rc" "real-binary status passthrough"
}
