# koji-doc-status: the ## Load on Kick-Off bullet parser and the /kick-off
# lessons-focus signal (--kickoff-focus).

DS="$KOJI/bin/koji-doc-status"
export PROJECT_ROOT="$TMP/proj"
export DOCS_PATH="$PROJECT_ROOT/.koji"
export PLANS_DIR="$DOCS_PATH/plans"
export RESEARCH_DIR="$DOCS_PATH/research"
mkdir -p "$PLANS_DIR" "$RESEARCH_DIR"
SESSION="$DOCS_PATH/agent-session.md"

_loko_paths() { "$DS" --load-on-kickoff | cut -f1 | tr '\n' ' '; }
_focus() { "$DS" --kickoff-focus "$SESSION" ""; }

test_loko_skips_bullets_inside_html_comments() {
  # The comment is the one templates/default/agent-session.md ships.
  cat > "$SESSION" <<'EOF'
# Agent Session Log

## Load on Kick-Off

<!-- Optional. Bullets here are auto-loaded by /kick-off into agent context.
     Use markdown links or plain paths. Example:
       - [<label>](docs/FOO.md)
       - docs/BAR.md
     /wrap will offer to add tagged docs whose covers paths were touched this session. -->

- docs/real.md
<!-- a one-line comment closes on its own line -->
- docs/after.md
- [Spec](docs/spec.md) <!-- an inline note keeps its bullet -->

---

<!-- Active sessions below. Older sessions archived to sessions/ directory. -->

## Session: one [Claude]

- docs/not-loko.md
EOF
  assert_eq "docs/real.md docs/after.md docs/spec.md " "$(_loko_paths)"
}

test_kickoff_focus_reads_only_the_last_notes_block() {
  # /wrap appends sessions at the bottom. The two older blocks hold 28 lines,
  # more than the 20-line cap, so a reader that keeps every block never
  # reaches the newest one.
  {
    printf '# Agent Session Log\n\n'
    for s in one two three; do
      printf '## Session: %s [Claude]\n\n### Summary\n\nDid %s.\n\n### Notes for Next Session\n\n' "$s" "$s"
      for i in $(seq 1 12); do printf 'note-%s-%02d\n' "$s" "$i"; done
      printf '\n'
    done
  } > "$SESSION"
  local out; out="$(_focus)"
  assert_contains "note-three-01" "$out" "newest notes, first line"
  assert_contains "note-three-12" "$out" "newest notes, last line"
  assert_not_contains "note-one-" "$out" "oldest notes"
  assert_not_contains "note-two-" "$out" "older notes"
}

test_kickoff_focus_caps_the_last_block_at_20_lines() {
  {
    printf '## Session: one [Claude]\n\n### Notes for Next Session\n\n'
    for i in $(seq 1 30); do printf 'line-%02d\n' "$i"; done
  } > "$SESSION"
  # The 20 lines are the blank line under the heading and line-01..line-19.
  local out; out="$(_focus)"
  assert_contains "line-19" "$out" "line 20 of the block"
  assert_not_contains "line-20" "$out" "line 21 of the block"
}
