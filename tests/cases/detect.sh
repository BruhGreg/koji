# koji-detect: config cascade, enum resolver, comment stripping, sourceability.
# Each test writes a scratch project with its own .koji.yaml; KOJI_STATE_DIR is
# pointed at $TMP so the real global config can't leak in.

_detect() {   # _detect "<yaml body or empty>" → koji-detect stdout (stderr → $TMP/detect.err)
  local dir="$TMP/proj-$RANDOM$RANDOM"
  mkdir -p "$dir"
  [ -n "$1" ] && printf '%s\n' "$1" > "$dir/.koji.yaml"
  (cd "$dir" && KOJI_STATE_DIR="$TMP/state" "$KOJI/bin/koji-detect" 2>"$TMP/detect.err")
}
_var() {      # _var "<yaml>" VAR → value of VAR after sourcing the output
  local out; out="$(_detect "$1")" || { echo "DETECT_FAILED"; return; }
  ( eval "$out"; eval "printf '%s' \"\${$2:-}\"" )
}

README_BLOCK='docs_dir: .koji              # where session docs live
template: default            # "default" (full) or "simple" (minimal)
archive:
  strategy: dated            # comment
  threshold: 7               # archive when this many sessions exist
  # a full-line comment inside the block must not end it
  keep: 2
wrap:
  starter_prompt: false      # existing key
  prompts: off               # on|off
  commit_prompt: on          # explicit on overrides prompts: off
  commit_gate: "npm run lint:check"   # quoted, with a colon inside
duet:
  reviewer: claude-rounds+codex-final   # hybrid
  claude_reviewer_model: opus
  codex_effort: high'

test_defaults_without_config() {
  assert_eq on     "$(_var "" WRAP_PROMPTS)" WRAP_PROMPTS
  assert_eq on     "$(_var "" WRAP_COMMIT_PROMPT)" WRAP_COMMIT_PROMPT
  assert_eq auto   "$(_var "" WRAP_COMMIT_GATE)" WRAP_COMMIT_GATE
  assert_eq codex  "$(_var "" DUET_REVIEWER)" DUET_REVIEWER
  assert_eq inherit "$(_var "" DUET_CLAUDE_MODEL)" DUET_CLAUDE_MODEL
  assert_eq xhigh  "$(_var "" DUET_CODEX_EFFORT)" DUET_CODEX_EFFORT
  assert_eq docs   "$(_var "" DOCS_DIR)" DOCS_DIR
}

test_readme_block_with_trailing_comments() {
  assert_eq .koji   "$(_var "$README_BLOCK" DOCS_DIR)" "flat key + comment"
  assert_eq default "$(_var "$README_BLOCK" TEMPLATE)" "flat key + quoted comment text"
  assert_eq dated   "$(_var "$README_BLOCK" ARCHIVE_STRATEGY)" "nested + comment"
  assert_eq 7       "$(_var "$README_BLOCK" ARCHIVE_THRESHOLD)"
  assert_eq 2       "$(_var "$README_BLOCK" ARCHIVE_KEEP)" "survives full-line comment in block"
  assert_eq false   "$(_var "$README_BLOCK" WRAP_STARTER)"
  assert_eq off     "$(_var "$README_BLOCK" WRAP_PROMPTS)"
  assert_eq on      "$(_var "$README_BLOCK" WRAP_COMMIT_PROMPT)" "explicit on beats prompts: off"
  assert_eq "npm run lint:check" "$(_var "$README_BLOCK" WRAP_COMMIT_GATE)" "quoted value keeps colon, drops comment"
  assert_eq claude-rounds+codex-final "$(_var "$README_BLOCK" DUET_REVIEWER)"
  assert_eq opus    "$(_var "$README_BLOCK" DUET_CLAUDE_MODEL)"
  assert_eq high    "$(_var "$README_BLOCK" DUET_CODEX_EFFORT)"
  assert_eq ""      "$(cat "$TMP/detect.err")" "no warnings for a valid block"
}

test_boolean_aliases_for_toggles() {
  assert_eq off "$(_var $'wrap:\n  prompts: false' WRAP_PROMPTS)" "false → off"
  assert_eq off "$(_var $'wrap:\n  prompts: false' WRAP_COMMIT_PROMPT)" "commit_prompt follows prompts"
  assert_eq on  "$(_var $'wrap:\n  prompts: yes' WRAP_PROMPTS)" "yes → on"
  assert_eq off "$(_var $'wrap:\n  prompts: 0' WRAP_PROMPTS)" "0 → off"
  assert_eq on  "$(_var $'wrap:\n  prompts: off\n  commit_prompt: true' WRAP_COMMIT_PROMPT)" "true → on"
}

test_invalid_enum_warns_on_stderr_and_falls_back() {
  assert_eq codex "$(_var $'duet:\n  reviewer: gpt5' DUET_REVIEWER)" "typo → default"
  assert_contains "duet.reviewer" "$(cat "$TMP/detect.err")" "WARN names the key"
  assert_eq on "$(_var $'wrap:\n  prompts: typo' WRAP_PROMPTS)" "prompts typo fails safe to on"
  assert_eq xhigh "$(_var $'duet:\n  codex_effort: medium' DUET_CODEX_EFFORT)"
  assert_eq inherit "$(_var $'duet:\n  claude_reviewer_model: haiku' DUET_CLAUDE_MODEL)"
}

test_output_is_sourceable_even_with_warning() {
  local out rc=0
  out="$(_detect $'duet:\n  reviewer: nope\nwrap:\n  commit_gate: echo "hi there"  # spaces + quotes')"
  ( set -e; eval "$out" ) || rc=$?
  assert_exit 0 "$rc" "eval under set -e"
  assert_eq 'echo "hi there"' "$( eval "$out"; printf '%s' "$WRAP_COMMIT_GATE" )" "%q round-trip"
  assert_not_contains "WARN" "$out" "warning never lands on stdout"
}

test_single_quoted_and_url_values() {
  assert_eq "make check" "$(_var $'wrap:\n  commit_gate: \'make check\'  # note' WRAP_COMMIT_GATE)"
  assert_eq "https://x.test/a#frag" "$(_var $'docs_dir: https://x.test/a#frag' DOCS_DIR)" "# without leading space is not a comment"
}

test_escaped_quotes_inside_quoted_value_survive() {
  assert_eq 'grep "x" f && echo ok' "$(_var $'wrap:\n  commit_gate: "grep \\"x\\" f && echo ok"  # gate' WRAP_COMMIT_GATE)" "escaped quotes + comment"
  assert_eq 'a \ b' "$(_var $'wrap:\n  commit_gate: "a \\\\ b"' WRAP_COMMIT_GATE)" "escaped backslash"
  assert_eq 'unterminated' "$(_var $'wrap:\n  commit_gate: "unterminated' WRAP_COMMIT_GATE)" "missing closing quote degrades to naive cut"
}

test_mixed_case_enum_values_are_accepted() {
  assert_eq claude "$(_var $'duet:\n  reviewer: Claude' DUET_REVIEWER)"
  assert_eq on     "$(_var $'wrap:\n  prompts: On' WRAP_PROMPTS)"
  assert_eq off    "$(_var $'wrap:\n  prompts: FALSE' WRAP_PROMPTS)"
  assert_eq ""     "$(cat "$TMP/detect.err")" "no warning for case variants"
}
