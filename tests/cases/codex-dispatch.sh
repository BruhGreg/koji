#!/usr/bin/env bash
# tests/cases/codex-dispatch.sh — koji-codex-exec and koji-codex-preflight.
#
# A fake `codex` on PATH records the argv and stdin it was handed, so the
# dispatch contract can be asserted without spending a real call.

EXEC="$KOJI/bin/koji-codex-exec"
PRE="$KOJI/bin/koji-codex-preflight"

# The harness guard fires before argument validation, so a suite run from inside
# a codex session would return 78 everywhere and the fake CLI would never run —
# 14 of these tests fail, and two pass for the wrong reason. The guard tests set
# these explicitly; everything else must start from a clean environment.
unset CODEX_THREAD_ID CODEX_SANDBOX

_fake_codex() {   # a PATH whose `codex` records what it received
  mkdir -p "$TMP/fake"
  cat > "$TMP/fake/codex" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$TMP/argv.txt"
cat > "$TMP/stdin.txt"
printf '[]\n'
EOF
  chmod +x "$TMP/fake/codex"
  printf '%s' "$TMP/fake:$PATH"
}

# --- argument validation ------------------------------------------------------
# These are the fresh-shell failures: a dispatch block that never restored
# $TIMEOUT or $EFFORT. They must name the cause, not fail obscurely downstream.
#
# The code is 79, deliberately not 2: `codex exec --bad-flag` exits 2, and so
# does koji-timeout on a bad duration. Carrying "your dispatch block is
# malformed" on 2 would let a codex flag rename hard-stop every duet run.
test_refuses_unrestored_variables() {
  local rc=0
  printf 'p' | "$EXEC" "" xhigh "$KOJI" 2>"$TMP/e1" || rc=$?
  assert_exit 79 "$rc" "empty TIMEOUT"
  assert_file_contains 'did not restore $TIMEOUT' "$TMP/e1"
  rc=0; printf 'p' | "$EXEC" 60 "" "$KOJI" 2>"$TMP/e2" || rc=$?
  assert_exit 79 "$rc" "empty EFFORT"
  assert_file_contains 'did not restore $EFFORT' "$TMP/e2"
  rc=0; printf 'p' | "$EXEC" 60 xhigh /nonexistent-koji-root 2>/dev/null || rc=$?
  assert_exit 79 "$rc" "bad project root"
  # A closed domain, not merely non-empty: $EFFORT lands inside codex's -c TOML.
  rc=0; printf 'p' | "$EXEC" 60 'xhigh" foo="bar' "$KOJI" 2>/dev/null || rc=$?
  assert_exit 79 "$rc" "effort outside max|xhigh|high"
}

# --- the dispatch contract ----------------------------------------------------
test_fixes_the_sandbox_and_effort_flags() {
  local path; path=$(_fake_codex)
  printf 'PROMPT-BODY\n' | env PATH="$path" "$EXEC" 60 max "$KOJI" >/dev/null 2>&1
  local argv; argv=$(cat "$TMP/argv.txt")
  assert_contains "-s read-only" "$argv" "read-only cannot be dropped"
  assert_contains "-C $KOJI" "$argv" "project root"
  assert_contains 'model_reasoning_effort="max"' "$argv" "effort passed through"
  assert_contains "exec -" "$argv" "prompt read from stdin"
  # No model pin on purpose: it resolves from ~/.codex/config.toml, so a new
  # model needs no koji change and nobody is broken by lacking a pinned one.
  assert_not_contains "-c model=" "$argv" "model stays unpinned"
}

test_prepends_the_boundary_before_the_prompt() {
  local path; path=$(_fake_codex)
  printf 'PROMPT-BODY\n' | env PATH="$path" "$EXEC" 60 xhigh "$KOJI" >/dev/null 2>&1
  assert_file_contains "Read files only under the repository at $KOJI" "$TMP/stdin.txt"
  # Filesystem-scoped, not a blanket reading ban: /triangulate invites web
  # research, and duet-plan critiques a plan rather than code.
  assert_file_contains "does not restrict web research" "$TMP/stdin.txt"
  assert_file_contains "PROMPT-BODY" "$TMP/stdin.txt"
  # Order matters: a boundary after the prompt is a footnote, not a constraint.
  local boundary_line prompt_line
  boundary_line=$(grep -n "Read files only under" "$TMP/stdin.txt" | head -1 | cut -d: -f1)
  prompt_line=$(grep -n "PROMPT-BODY" "$TMP/stdin.txt" | head -1 | cut -d: -f1)
  if [ "$boundary_line" -lt "$prompt_line" ]; then _ok; else _fail "boundary must precede the prompt"; fi
}

test_reply_and_status_pass_through_untouched() {
  local path; path=$(_fake_codex)
  local out rc=0
  out=$(printf 'p\n' | env PATH="$path" "$EXEC" 60 xhigh "$KOJI" 2>/dev/null) || rc=$?
  assert_exit 0 "$rc" "status"
  assert_eq "[]" "$out" "stdout is the reply, nothing prepended to it"
}

test_status_survives_a_codex_that_ignores_stdin() {
  # The regression this guards: as a pipeline under pipefail, a codex that
  # answers and exits without draining a large prompt gave `cat` a SIGPIPE and
  # the wrapper returned 141 with a complete reply on stdout — which the
  # classifier reads as ERROR and throws the review away.
  mkdir -p "$TMP/nodrain"
  cat > "$TMP/nodrain/codex" <<'EOF'
#!/usr/bin/env bash
printf '[]\n'
exit 0
EOF
  chmod +x "$TMP/nodrain/codex"
  printf 'x%.0s' $(seq 1 200000) > "$TMP/bigprompt.txt"
  local out rc=0
  out=$(env PATH="$TMP/nodrain:$PATH" "$EXEC" 60 xhigh "$KOJI" < "$TMP/bigprompt.txt" 2>/dev/null) || rc=$?
  assert_exit 0 "$rc" "codex exit 0 without draining stdin"
  assert_eq "[]" "$out" "reply still intact"
}

test_large_prompt_is_not_rejected_as_empty() {
  # Every other test here uses a prompt of a few bytes, which is exactly why
  # this slipped through: the emptiness check was `tail -c +N | grep -q`, and
  # grep -q exits on the first match, SIGPIPEing tail. Under pipefail that
  # reports 141 and a valid 100KB prompt is refused as empty — but only above
  # the ~64KB pipe buffer, so small fixtures all passed.
  local path; path=$(_fake_codex)
  { printf 'REAL PROMPT HEADER\n'; printf 'x%.0s' $(seq 1 120000); printf '\nREAL PROMPT TAIL\n'; } > "$TMP/big.txt"
  local rc=0
  env PATH="$path" "$EXEC" 60 xhigh "$KOJI" < "$TMP/big.txt" >/dev/null 2>"$TMP/big.err" || rc=$?
  assert_exit 0 "$rc" "a large prompt must reach codex"
  assert_file_not_contains "prompt is empty" "$TMP/big.err" "large prompt misread as empty"
  assert_file_contains "REAL PROMPT TAIL" "$TMP/stdin.txt" "the whole prompt was delivered"
}

test_failed_prompt_transfer_fails_the_call() {
  local path; path=$(_fake_codex)
  rm -f "$TMP/argv.txt"
  # A DIRECTORY as stdin opens successfully and fails during read — a
  # nonexistent file would be rejected by the calling shell before the wrapper
  # ever ran, so the assertion would hold even with the wrapper replaced by
  # `true`. A producer in front of codex can otherwise swallow the read error
  # and hand back a clean exit with an empty reply: a false PASS manufactured by
  # the wrapper.
  local rc=0
  env PATH="$path" "$EXEC" 60 xhigh "$KOJI" < "$TMP" >/dev/null 2>/dev/null || rc=$?
  assert_ne "0" "$rc" "unreadable stdin must not read as success"
  if [ -f "$TMP/argv.txt" ]; then _fail "codex was started despite an unreadable prompt"; else _ok; fi
}

test_empty_prompt_is_refused() {
  local path; path=$(_fake_codex)
  rm -f "$TMP/argv.txt"
  # A dispatch block whose $CODEX_PROMPT was never restored writes a lone
  # newline. The boundary paragraph would make that non-empty, and codex would
  # answer a question it was never asked — an AGREE or [] that reads as a real
  # verdict.
  local rc=0
  printf '\n' | env PATH="$path" "$EXEC" 60 xhigh "$KOJI" >/dev/null 2>/dev/null || rc=$?
  assert_ne "0" "$rc" "empty prompt must not dispatch"
  if [ -f "$TMP/argv.txt" ]; then _fail "codex was started with an empty prompt"; else _ok; fi
}

test_wrapper_refuses_under_codex_even_without_the_preamble() {
  local path; path=$(_fake_codex)
  rm -f "$TMP/argv.txt"
  # Second line of defence: a dispatch reached directly — a resumed block, a
  # retry pasted on its own — must not be able to start codex as its own
  # outside voice.
  local rc=0
  printf 'a real prompt body\n' | env PATH="$path" CODEX_SANDBOX=1 "$EXEC" 60 xhigh "$KOJI" >/dev/null 2>/dev/null || rc=$?
  assert_exit 78 "$rc" "wrapper harness guard"
  if [ -f "$TMP/argv.txt" ]; then _fail "codex was started despite a harness mismatch"; else _ok; fi
}

# --- preflight ----------------------------------------------------------------
test_preflight_passes_in_a_normal_session() {
  local rc=0
  env -u CODEX_THREAD_ID -u CODEX_SANDBOX "$PRE" >/dev/null 2>&1 || rc=$?
  assert_exit 0 "$rc" "clean session"
}

test_preflight_refuses_under_codex() {
  local rc=0
  env CODEX_SANDBOX=1 "$PRE" 2>"$TMP/pre.err" || rc=$?
  assert_exit 78 "$rc" "CODEX_SANDBOX"
  assert_file_contains "harness mismatch" "$TMP/pre.err"
  assert_file_contains "Missing coverage" "$TMP/pre.err"
  # The substitution ban is the whole point: under codex, a Claude substitute is
  # Reviewer A reviewing itself.
  assert_file_contains "do NOT substitute" "$TMP/pre.err"
  rc=0; env CODEX_THREAD_ID=abc "$PRE" >/dev/null 2>&1 || rc=$?
  assert_exit 78 "$rc" "CODEX_THREAD_ID"
}

test_preflight_starts_no_codex_process_when_it_refuses() {
  local path; path=$(_fake_codex)
  rm -f "$TMP/argv.txt"
  env PATH="$path" CODEX_SANDBOX=1 "$PRE" >/dev/null 2>&1
  if [ -f "$TMP/argv.txt" ]; then _fail "codex was started despite a harness mismatch"; else _ok; fi
}

test_preflight_warns_on_known_bad_cli_versions() {
  mkdir -p "$TMP/badver"
  # The warning lands on stderr with the version on stdout, and a startup warning
  # ahead of it: `head -1` would parse the warning and miss the version entirely.
  cat > "$TMP/badver/codex" <<'EOF'
#!/usr/bin/env bash
echo "WARNING: proceeding, even though we could not create PATH aliases" >&2
echo "codex-cli 0.120.1"
EOF
  chmod +x "$TMP/badver/codex"
  local rc=0
  env -u CODEX_SANDBOX -u CODEX_THREAD_ID PATH="$TMP/badver:$PATH" "$PRE" 2>"$TMP/ver.err" || rc=$?
  assert_exit 0 "$rc" "version warning is non-blocking"
  assert_file_contains "stdin deadlock" "$TMP/ver.err"
  # Anchored so a later patch release is not swept up with the bad ones.
  cat > "$TMP/badver/codex" <<'EOF'
#!/usr/bin/env bash
echo "codex-cli 0.120.10"
EOF
  env -u CODEX_SANDBOX -u CODEX_THREAD_ID PATH="$TMP/badver:$PATH" "$PRE" 2>"$TMP/ver2.err"
  assert_file_not_contains "stdin deadlock" "$TMP/ver2.err" "0.120.10 is not a bad version"
}

test_both_harness_guards_check_the_same_variables() {
  # The guard is deliberately duplicated — the preflight catches it early and
  # visibly, the wrapper catches a dispatch that never ran a preamble. Two lists
  # means they can drift, and adding a new codex marker to only one silently
  # narrows the backstop. Pin them to each other instead.
  local pre_vars exec_vars
  # An OPEN pattern. A closed set like CODEX_(THREAD_ID|SANDBOX) can only ever
  # find the two variables the test itself names, so a third marker added to one
  # file is invisible to both greps and the test passes while the guards differ.
  # Matching the dereference form also excludes prose mentions.
  pre_vars=$(grep -oE '\$\{CODEX_[A-Z_]+:-\}' "$PRE" | sort -u | tr '\n' ' ')
  exec_vars=$(grep -oE '\$\{CODEX_[A-Z_]+:-\}' "$EXEC" | sort -u | tr '\n' ' ')
  assert_eq "$pre_vars" "$exec_vars" "preflight and wrapper guard the same env vars"
  assert_ne "" "$pre_vars" "the guard variables are still present at all"
}

test_dispatch_actually_runs_under_koji_timeout() {
  # The wrapper's headline guarantee is that codex is never unwrapped, but the
  # fake codex records the same argv either way — so deleting the koji-timeout
  # prefix passes every other test here. Prove the deadline is live instead.
  mkdir -p "$TMP/hang"
  printf '#!/usr/bin/env bash\nsleep 30\n' > "$TMP/hang/codex"
  chmod +x "$TMP/hang/codex"
  local rc=0
  printf 'a real prompt body\n' | env PATH="$TMP/hang:$PATH" "$EXEC" 1 xhigh "$KOJI" >/dev/null 2>&1 || rc=$?
  assert_exit 124 "$rc" "the dispatch is wrapped by koji-timeout"
}

test_supervisor_failure_is_not_a_caller_error() {
  # An unusable TMPDIR is 125 (degrades as ERROR), never 79 (terminal, blames
  # the dispatch block) — the contract references/reviewer-backend.md states.
  local path; path=$(_fake_codex)
  local rc=0
  printf 'a real prompt body\n' | env PATH="$path" TMPDIR=/nonexistent-koji-dispatch "$EXEC" 60 xhigh "$KOJI" >/dev/null 2>&1 || rc=$?
  assert_exit 125 "$rc" "unusable TMPDIR degrades, not blames"
}

test_timeout_domain_is_bounded() {
  local path; path=$(_fake_codex)
  local rc=0
  printf 'p\n' | env PATH="$path" "$EXEC" 0 xhigh "$KOJI" >/dev/null 2>&1 || rc=$?
  assert_exit 79 "$rc" "zero timeout"
  rc=0; printf 'p\n' | env PATH="$path" "$EXEC" 99999999999999999999 xhigh "$KOJI" >/dev/null 2>&1 || rc=$?
  assert_exit 79 "$rc" "out-of-range timeout"
}

test_a_lost_stdin_redirect_fails_instead_of_stalling() {
  # Every call site redirects a regular file, which EOFs instantly. A block that
  # drops its `< "$PROMPT_TXT"` inherits the harness's stdin, which can be a
  # socket that never EOFs — uncapped, that hangs forever with no reply, no
  # CE=$?, and no .exit file, so the run never completes. It must fail fast.
  local path; path=$(_fake_codex)
  # A FIFO held open READ-WRITE by this shell. Two earlier fixtures were wrong:
  # /dev/zero never EOFs but floods the buffer with gigabytes, and a plain
  # `< fifo` blocks in the SHELL's open() before the wrapper is even spawned, so
  # the cap can never fire. O_RDWR on a FIFO returns immediately and never sees
  # EOF, which is the shape of the harness socket this guards against.
  mkfifo "$TMP/never" 2>/dev/null || true
  exec 9<> "$TMP/never"
  local rc=0
  env PATH="$path" KOJI_BUF_CAP=2 "$EXEC" 30 xhigh "$KOJI" <&9 >/dev/null 2>&1 || rc=$?
  exec 9>&-
  assert_ne "0" "$rc" "an unbounded stdin must not be dispatched"
  assert_ne "124" "$rc" "and it is reported as a caller error, not a raw timeout"
}

test_environment_failures_degrade_rather_than_blame_the_caller() {
  # grep exiting non-zero is not always "no match": 2 is a read error, 127 is
  # missing. Reporting those as 79 would hard-stop an unattended run for a
  # broken environment, where 125 degrades.
  mkdir -p "$TMP/nogrep"
  local b p
  for b in bash cat mktemp rm wc printf sleep kill; do
    p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$TMP/nogrep/$b"
  done
  cat > "$TMP/nogrep/codex" <<'EOF'
#!/usr/bin/env bash
printf '[]\n'
EOF
  chmod +x "$TMP/nogrep/codex"
  local rc=0
  printf 'a real prompt body\n' | env PATH="$TMP/nogrep" "$EXEC" 30 xhigh "$KOJI" >/dev/null 2>&1 || rc=$?
  assert_exit 125 "$rc" "a missing grep degrades, it does not blame the caller"
}
