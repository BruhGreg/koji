#!/usr/bin/env bash
# tests/cases/session-placeholders.sh — koji-session-placeholders.
#
# Runs against the real shipped templates, so a template edit that introduces a
# token the checker can't see fails here.

SP="$KOJI/bin/koji-session-placeholders"
DEFAULT_TPL="$KOJI/templates/default/SESSION_TEMPLATE.md"
SIMPLE_TPL="$KOJI/templates/simple/SESSION_TEMPLATE.md"

# $1 = template, $2 = entry, $3 = AGENTS value. Sets $OUT and $RC.
_run() {
  RC=0
  OUT="$(AGENTS="${3:-Claude}" "$SP" "$1" "$2" 2>/dev/null)" || RC=$?
}

_lines() { printf '%s\n' "$1" | grep -c . | tr -d ' '; }

# Independent oracle for "how many placeholders should a verbatim entry report":
# an awk match-loop rather than the script's `grep -oE`, and a whole-file gsub
# rather than the script's line-state machine, so the two only agree if they
# really agree. Computed from the template on disk, never hard-coded — the
# shipped templates gain and lose placeholders between releases.
#
# `<!--([^-]|-[^-]|--[^>])*-->` is the non-greedy-comment idiom: awk has no
# lazy quantifier, and `<!--.*-->` on a whole file would swallow everything
# between the FIRST opener and the LAST closer. `sed '/<!--/,/-->/d'` has the
# same bug for a different reason (the end address is searched from the next
# line, so a one-line comment runs on to the next comment).
_expected_count() {
  awk '
    { all = all $0 "\n" }
    END {
      gsub(/<!--([^-]|-[^-]|--[^>])*-->/, "", all)
      m = split(all, L, "\n")
      for (j = 1; j <= m; j++) {
        line = L[j]
        while (match(line, /\[[^]]*\]/)) {
          tok  = substr(line, RSTART, RLENGTH)
          line = substr(line, RSTART + RLENGTH)
          if (tok == "[ ]" || tok == "[x]" || tok == "[X]" || tok == "[Claude]") continue
          if (!(tok in seen)) { seen[tok] = 1; n++ }
        }
      }
      print n + 0
    }' "$1"
}

# An entry that is the template, untouched: every placeholder still there.
test_verbatim_default_template_reports_everything() {
  _run "$DEFAULT_TPL" "$DEFAULT_TPL"
  assert_exit 1 "$RC" "unfilled entry exits 1"
  assert_eq "$(_expected_count "$DEFAULT_TPL")" "$(_lines "$OUT")" "placeholder count"
  assert_contains "[Session Name]" "$OUT"
  assert_contains "[Brief summary of the session goals and outcomes]" "$OUT"
  assert_contains "[Any blockers, open questions, or immediate next steps]" "$OUT"
}

# Checkboxes are structure and [Claude] is a filled Agent line — neither is
# boilerplate, both must stay out of the report.
test_checkboxes_and_agent_are_excluded() {
  _run "$DEFAULT_TPL" "$DEFAULT_TPL"
  assert_not_contains "[ ]"      "$OUT" "checkbox"
  assert_not_contains "[x]"      "$OUT" "checked checkbox"
  assert_not_contains "[Claude]" "$OUT" "agent name"
}

test_output_is_in_template_order_and_deduplicated() {
  _run "$DEFAULT_TPL" "$DEFAULT_TPL"
  local first second
  first="$(printf '%s\n' "$OUT" | sed -n 1p)"
  second="$(printf '%s\n' "$OUT" | sed -n 2p)"
  assert_eq "[Session Name]" "$first"  "first token"
  assert_eq "[Tag]"          "$second" "second token"
  # [Achievement 1] and [Description] each appear twice in the template.
  assert_eq "1" "$(printf '%s\n' "$OUT" | grep -cF '[Achievement 1]' | tr -d ' ')" "dedup"
  assert_eq "1" "$(printf '%s\n' "$OUT" | grep -cF '[Description]'   | tr -d ' ')" "dedup"
}

test_verbatim_simple_template_reports_everything() {
  _run "$SIMPLE_TPL" "$SIMPLE_TPL"
  assert_exit 1 "$RC" "unfilled entry exits 1"
  assert_eq "$(_expected_count "$SIMPLE_TPL")" "$(_lines "$OUT")" "placeholder count"
  assert_contains "[What was completed]"     "$OUT"
  assert_contains "[Important choices made]" "$OUT"
  assert_contains "[What to do next]"        "$OUT"
}

test_filled_entry_is_clean() {
  local entry="$TMP/filled.md"
  cat >"$entry" <<'ENTRY'
## Session: Ship the amend gate [feat]

**Date**: 2026-09-03
**Agent**: [Claude]

### Summary

Added koji-amendable and wired /wrap's commit step to it.

### Key Achievements

1.  **Helpers**:
    - koji-amendable emits a sourceable verdict
    - koji-tree-fingerprint detects tree drift under a reviewer

2.  **Wiring**:
    - /wrap reads AMENDABLE instead of guessing

### Test Results

- [x] **Test A**: tests/run.sh amendable — all green
- [x] **Test B**: tests/run.sh tree-fingerprint — all green

### Notes for Next Session

Ship it, then teach /duet-impl the same gate.
ENTRY
  _run "$DEFAULT_TPL" "$entry"
  assert_exit 0 "$RC" "filled entry exits 0"
  assert_eq "" "$OUT" "filled entry prints nothing"
}

test_single_surviving_placeholder() {
  local entry="$TMP/partial.md"
  cat >"$entry" <<'ENTRY'
## Session: Half-written [chore]

**Date**: 2026-09-03
**Agent**: [Claude]

### Summary

Wrote some of it.

### Key Achievements

1.  **Helpers**:
    - one thing landed

### Test Results

- [x] **Test A**: [Description]

### Notes for Next Session

Finish the entry.
ENTRY
  _run "$DEFAULT_TPL" "$entry"
  assert_exit 1 "$RC" "one placeholder left"
  assert_eq "[Description]" "$OUT" "exactly the surviving token"
}

# $AGENTS is a list: every name in it is a filled Agent line, not boilerplate.
test_agents_list_excludes_every_name() {
  local tpl="$TMP/multi-agent-template.md"
  cat >"$tpl" <<'TPL'
## Session: [Session Name]

**Agent**: [Claude]
**Reviewer**: [Gemini]
**Owner**: [Someone]
TPL
  cp "$tpl" "$TMP/multi-agent-entry.md"
  local entry="$TMP/multi-agent-entry.md"

  _run "$tpl" "$entry" "Claude Gemini"
  assert_not_contains "[Claude]" "$OUT" "first agent excluded"
  assert_not_contains "[Gemini]" "$OUT" "second agent excluded"
  assert_contains     "[Someone]" "$OUT" "non-agent placeholder still reported"

  # Same files, narrower agent list: [Gemini] becomes boilerplate again.
  _run "$tpl" "$entry" "Claude"
  assert_contains "[Gemini]" "$OUT" "not an agent any more"
}

# A token must be in BOTH files: a placeholder the entry dropped is not
# reported, and an entry-only bracket token is not either.
test_only_tokens_present_in_both_files_are_reported() {
  local tpl="$TMP/both-template.md"
  local entry="$TMP/both-entry.md"
  printf '%s\n' '[In Both]' '[Template Only]' >"$tpl"
  printf '%s\n' '[In Both]' '[Entry Only]'    >"$entry"
  _run "$tpl" "$entry"
  assert_eq "[In Both]" "$OUT" "intersection only"
  assert_exit 1 "$RC"
}

test_usage_errors() {
  local rc=0
  "$SP" >/dev/null 2>&1 || rc=$?
  assert_exit 2 "$rc" "no arguments"

  rc=0
  "$SP" "$DEFAULT_TPL" >/dev/null 2>&1 || rc=$?
  assert_exit 2 "$rc" "one argument"

  rc=0
  "$SP" "$DEFAULT_TPL" "$TMP/does-not-exist.md" >/dev/null 2>&1 || rc=$?
  assert_exit 2 "$rc" "missing entry file"

  rc=0
  "$SP" "$TMP/no-such-template.md" "$DEFAULT_TPL" >/dev/null 2>&1 || rc=$?
  assert_exit 2 "$rc" "missing template file"
}

test_html_comments_in_template_are_not_placeholders() {
  local tpl="$TMP/tpl-comments.md" entry="$TMP/entry-comments.md" out rc=0
  printf '## Session: [Session Name]\n\n<!-- guidance: add `**AI-lens**: [angle | none | n/a (reason)]`\n   spanning two lines [not a placeholder] -->\n\n**Field**: [Real]\n' > "$tpl"
  # Entry keeps the comment text verbatim (as an author might) but fills the real slots.
  printf '## Session: Fixed name\n\n<!-- guidance: add `**AI-lens**: [angle | none | n/a (reason)]`\n   spanning two lines [not a placeholder] -->\n\n**Field**: done\n' > "$entry"
  out="$("$KOJI/bin/koji-session-placeholders" "$tpl" "$entry")" || rc=$?
  assert_exit 0 "$rc" "comment-only brackets never count"
  assert_eq "" "$out"
  # And the real slot is still caught when it survives.
  printf '## Session: Fixed name\n\n**Field**: [Real]\n' > "$entry"
  rc=0; out="$("$KOJI/bin/koji-session-placeholders" "$tpl" "$entry")" || rc=$?
  assert_exit 1 "$rc"
  assert_eq "[Real]" "$out"
}

# Templates carry authoring guidance in HTML comments. The brackets in there
# are examples of what a placeholder looks like, not placeholders — even when
# the entry copied the comment through verbatim.
test_html_comment_guidance_is_not_a_placeholder() {
  local tpl="$TMP/commented-template.md"
  local entry="$TMP/commented-entry.md"
  cat >"$tpl" <<'TPL'
## Session: [Session Name]

<!-- Project obligations go here as `**Field**: [not a placeholder]` lines,
     e.g. `**AI-lens**: [angle | none | n/a (reason)]`. This comment spans
     more than one line on purpose. -->

**Date**: YYYY-MM-DD
TPL
  cat >"$entry" <<'ENTRY'
## Session: Ship the comment strip

<!-- Project obligations go here as `**Field**: [not a placeholder]` lines,
     e.g. `**AI-lens**: [angle | none | n/a (reason)]`. This comment spans
     more than one line on purpose. -->

**Date**: 2026-09-03
ENTRY
  _run "$tpl" "$entry"
  assert_exit 0 "$RC" "comment brackets do not block the entry"
  assert_eq "" "$OUT" "nothing reported"
}

# The strip is per-span, not per-line: a comment sharing a line with a real
# placeholder must not take the placeholder with it.
test_inline_comment_does_not_hide_a_real_placeholder() {
  local tpl="$TMP/inline-template.md"
  local entry="$TMP/inline-entry.md"
  printf '%s\n' '**Field**: [Real] <!-- e.g. [Fake] -->' >"$tpl"
  cp "$tpl" "$entry"
  _run "$tpl" "$entry"
  assert_exit 1 "$RC" "the real placeholder still counts"
  assert_eq "[Real]" "$OUT" "only the uncommented token"
}
