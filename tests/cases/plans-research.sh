# koji-plans-research --set-next-step + the symmetric quoted-scalar reader.

PR="$KOJI/bin/koji-plans-research"
export PROJECT_ROOT="$TMP/proj"
export PLANS_DIR="$PROJECT_ROOT/.koji/plans"
export RESEARCH_DIR="$PROJECT_ROOT/.koji/research"
mkdir -p "$PLANS_DIR" "$RESEARCH_DIR"

_plan() {   # _plan <name> <frontmatter lines...> → path (body is fixed)
  local f="$PLANS_DIR/$1.md"; shift
  { printf -- '---\n'; for l in "$@"; do printf '%s\n' "$l"; done; printf -- '---\n\n# Title\n\nbody line with $(not expanded) and `ticks`\n'; } > "$f"
  printf '%s' "$f"
}
_next() { "$PR" --get "$1" | cut -f7; }
_body() { awk 'f{print} /^---[[:space:]]*$/{c++; if(c==2)f=1}' "$1"; }

test_replaces_existing_next_step() {
  local f; f="$(_plan a "status: pending" "next-step: old text")"
  "$PR" --set-next-step "$f" "new text" >/dev/null
  assert_eq "new text" "$(_next "$f")"
  assert_eq 1 "$(grep -c '^next-step:' "$f")" "exactly one next-step line"
  assert_file_contains 'next-step: "new text"' "$f" "stored double-quoted"
}

test_inserts_when_absent_and_keeps_body() {
  local f before after; f="$(_plan b "status: pending")"
  before="$(_body "$f")"
  "$PR" --set-next-step "$f" "confirm issue #123: check quotes" >/dev/null
  after="$(_body "$f")"
  assert_eq "$before" "$after" "body untouched"
  assert_eq "confirm issue #123: check quotes" "$(_next "$f")" "# and : round-trip"
  assert_eq pending "$("$PR" --get "$f" | cut -f3)" "status still read"
}

test_quotes_and_backslashes_round_trip() {
  local f v; f="$(_plan c "status: pending")"
  v='say "hi" to C:\path\ and a \" literal'
  "$PR" --set-next-step "$f" "$v" >/dev/null
  assert_eq "$v" "$(_next "$f")"
}

test_rejects_multiline_and_empty() {
  local f rc=0; f="$(_plan d "status: pending" "next-step: keep")"
  "$PR" --set-next-step "$f" $'line1\nline2' >/dev/null 2>&1 || rc=$?
  assert_exit 2 "$rc" "newline rejected"
  rc=0; "$PR" --set-next-step "$f" $'a\tb' >/dev/null 2>&1 || rc=$?
  assert_exit 2 "$rc" "tab rejected"
  rc=0; "$PR" --set-next-step "$f" "" >/dev/null 2>&1 || rc=$?
  assert_exit 2 "$rc" "empty rejected"
  assert_eq keep "$(_next "$f")" "file unchanged after rejections"
}

test_refuses_without_frontmatter() {
  local f="$PLANS_DIR/nofm.md" rc=0
  printf '# Just a title\n\nbody\n' > "$f"
  "$PR" --set-next-step "$f" "x" >/dev/null 2>&1 || rc=$?
  assert_exit 3 "$rc"
  assert_eq "# Just a title" "$(head -1 "$f")" "file untouched"
}

test_crlf_preserved() {
  local f="$PLANS_DIR/crlf.md"
  printf -- '---\r\nstatus: pending\r\nnext-step: old\r\n---\r\n\r\nbody\r\n' > "$f"
  "$PR" --set-next-step "$f" "new" >/dev/null
  assert_eq 6 "$(grep -c $'\r$' "$f")" "every line still CRLF"
  assert_eq new "$(_next "$f")"
}

test_reader_still_handles_unquoted_and_single_quoted() {
  local f
  f="$(_plan e "status: pending" "next-step: do the thing  # trailing comment")"
  assert_eq "do the thing" "$(_next "$f")" "unquoted: comment stripped"
  f="$(_plan f "status: pending" "next-step: 'single # not a comment'")"
  assert_eq "single # not a comment" "$(_next "$f")" "single-quoted keeps #"
  f="$(_plan g "status: pending" 'next-step: "double # inside"  # outside')"
  assert_eq "double # inside" "$(_next "$f")" "double-quoted keeps inner #, drops outer comment"
}

test_set_status_still_works_alongside() {
  local f; f="$(_plan h "status: pending" "next-step: n")"
  "$PR" --set-status "$f" in-progress >/dev/null
  assert_eq in-progress "$("$PR" --get "$f" | cut -f3)"
  assert_eq n "$(_next "$f")"
}
