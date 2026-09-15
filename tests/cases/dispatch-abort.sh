#!/usr/bin/env bash
# tests/cases/dispatch-abort.sh — koji-dispatch-abort.
#
# Its contract is a COMPOSITION contract: not just "does it record and exit",
# but "does a `guard || exec helper` line actually stop the calling block".
# That distinction is the whole point — the first version of this helper was
# called without `exec`, recorded the status correctly, and then let the block
# fall through to the dispatch it existed to prevent. Unit-testing the helper
# alone passed; only a fixture shaped like a real call site catches it.

DA="$KOJI/bin/koji-dispatch-abort"

test_records_the_code_and_exits_with_it() {
  local rc=0
  "$DA" "$TMP/a.exit" 79 "some reason" 2>"$TMP/a.err" || rc=$?
  assert_exit 79 "$rc" "exits with the code it was given"
  assert_eq "79" "$(cat "$TMP/a.exit")" "records the code"
  assert_file_contains "some reason" "$TMP/a.err" "explains why"
}

test_rejects_a_non_numeric_code() {
  local rc=0
  "$DA" "$TMP/b.exit" notanumber "msg" 2>/dev/null || rc=$?
  assert_exit 79 "$rc" "a non-numeric code is itself a caller error"
}

test_rejects_codes_that_would_truncate() {
  # `exit` truncates mod 256, so a code of 256 exits 0 — a guard whose whole job
  # is to fail terminally would report success while the exit FILE said 256.
  local rc=0
  "$DA" "$TMP/t.exit" 256 "msg" 2>/dev/null || rc=$?
  assert_exit 79 "$rc" "256 would have exited 0"
  rc=0; "$DA" "$TMP/t.exit" 0 "msg" 2>/dev/null || rc=$?
  assert_exit 79 "$rc" "0 would read as a clean run"
  rc=0; "$DA" "$TMP/t.exit" 300 "msg" 2>/dev/null || rc=$?
  assert_exit 79 "$rc" "300 would have exited 44"
}

test_requires_its_arguments() {
  local rc=0; "$DA" 2>/dev/null || rc=$?
  assert_ne "0" "$rc" "no arguments"
  rc=0; "$DA" "$TMP/c.exit" 2>/dev/null || rc=$?
  assert_ne "0" "$rc" "no code"
}

test_still_exits_when_the_status_cannot_be_recorded() {
  # Nowhere to write is exactly when a silent success would be worst: the
  # collection site would see no file at all. It must still fail loudly.
  local rc=0
  "$DA" /nonexistent-koji-dir/x.exit 79 "msg" 2>"$TMP/d.err" || rc=$?
  assert_exit 79 "$rc" "unwritable exit file still exits with the code"
  assert_file_contains "could not record status" "$TMP/d.err" "says the record failed"
}

test_exec_form_stops_the_calling_block() {
  # THE load-bearing case. A dispatch block has no `set -e`, so without `exec`
  # the helper exits itself and the block sails on into the dispatch.
  cat > "$TMP/block.sh" <<EOF
#!/usr/bin/env bash
false || exec "$DA" "$TMP/e.exit" 79 "guard tripped"
echo REACHED > "$TMP/after"
EOF
  chmod +x "$TMP/block.sh"
  rm -f "$TMP/after" "$TMP/e.exit"
  local rc=0
  "$TMP/block.sh" 2>/dev/null || rc=$?
  assert_exit 79 "$rc" "the block exits with the terminal code"
  assert_eq "79" "$(cat "$TMP/e.exit")" "the status is recorded"
  if [ -f "$TMP/after" ]; then _fail "the block continued past the guard"; else _ok; fi
}

test_without_exec_the_block_would_continue() {
  # Pins WHY every call site uses `exec`. If this ever stops holding, bash
  # changed under us and the `exec` requirement needs revisiting — but until
  # then this is the trap the call sites are avoiding.
  cat > "$TMP/noexec.sh" <<EOF
#!/usr/bin/env bash
false || "$DA" "$TMP/f.exit" 79 "guard tripped"
echo REACHED > "$TMP/after2"
EOF
  chmod +x "$TMP/noexec.sh"
  rm -f "$TMP/after2"
  "$TMP/noexec.sh" >/dev/null 2>&1
  if [ -f "$TMP/after2" ]; then _ok; else _fail "expected the no-exec form to fall through — the exec requirement may be stale"; fi
}

test_every_skill_call_site_uses_exec() {
  # A guard written without `exec` is a no-op that looks like protection, so
  # check the shipped call sites directly rather than trusting review.
  local bad=0 f
  for f in "$KOJI"/*/SKILL.md; do
    if grep -n 'koji-dispatch-abort' "$f" | grep -qv 'exec ~/.claude/skills/koji/bin/koji-dispatch-abort'; then
      grep -n 'koji-dispatch-abort' "$f" | grep -v 'exec ~/.claude/skills/koji/bin/koji-dispatch-abort' | grep -qv '^\s*#' && bad=1
    fi
  done
  assert_eq "0" "$bad" "every call site invokes the helper with exec"
}
