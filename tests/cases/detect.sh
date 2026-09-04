# koji-detect: config cascade, comment stripping, sourceability, retired keys.
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

# A v0.8.0-era block: the `prompts`, `commit_prompt` and `duet:` keys were
# retired in v0.9.0 (wrap never prompts; the duet skills ask at run start).
# They must be ignored silently — no variable, no warning — so an old
# .koji.yaml keeps working.
README_BLOCK='docs_dir: .koji              # where session docs live
template: default            # "default" (full) or "simple" (minimal)
archive:
  strategy: dated            # comment
  threshold: 7               # archive when this many sessions exist
  # a full-line comment inside the block must not end it
  keep: 2
wrap:
  starter_prompt: false      # existing key
  prompts: off               # retired key
  commit_prompt: on          # retired key
  commit_gate: "npm run lint:check"   # quoted, with a colon inside
duet:
  reviewer: claude-rounds+codex-final   # retired block
  claude_reviewer_model: opus
  codex_effort: high'

test_defaults_without_config() {
  assert_eq auto   "$(_var "" WRAP_COMMIT_GATE)" WRAP_COMMIT_GATE
  assert_eq true   "$(_var "" WRAP_STARTER)" WRAP_STARTER
  assert_eq docs   "$(_var "" DOCS_DIR)" DOCS_DIR
}

test_readme_block_with_trailing_comments() {
  assert_eq .koji   "$(_var "$README_BLOCK" DOCS_DIR)" "flat key + comment"
  assert_eq default "$(_var "$README_BLOCK" TEMPLATE)" "flat key + quoted comment text"
  assert_eq dated   "$(_var "$README_BLOCK" ARCHIVE_STRATEGY)" "nested + comment"
  assert_eq 7       "$(_var "$README_BLOCK" ARCHIVE_THRESHOLD)"
  assert_eq 2       "$(_var "$README_BLOCK" ARCHIVE_KEEP)" "survives full-line comment in block"
  assert_eq false   "$(_var "$README_BLOCK" WRAP_STARTER)"
  assert_eq "npm run lint:check" "$(_var "$README_BLOCK" WRAP_COMMIT_GATE)" "quoted value keeps colon, drops comment"
  assert_eq ""      "$(cat "$TMP/detect.err")" "no warnings for a valid block"
}

test_retired_keys_are_ignored_silently() {
  local out
  out="$(_detect "$README_BLOCK")"
  for v in WRAP_PROMPTS WRAP_COMMIT_PROMPT DUET_REVIEWER DUET_CLAUDE_MODEL DUET_CODEX_EFFORT; do
    assert_not_contains "$v=" "$out" "$v is not emitted"
  done
  assert_eq "" "$(cat "$TMP/detect.err")" "retired keys produce no warning"
  assert_not_contains "WARN" "$out" "no warning on stdout either"
}

test_output_is_sourceable() {
  local out rc=0
  out="$(_detect $'wrap:\n  commit_gate: echo "hi there"  # spaces + quotes')"
  ( set -e; eval "$out" ) || rc=$?
  assert_exit 0 "$rc" "eval under set -e"
  assert_eq 'echo "hi there"' "$( eval "$out"; printf '%s' "$WRAP_COMMIT_GATE" )" "%q round-trip"
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

test_commit_gate_none_and_command() {
  assert_eq none "$(_var $'wrap:\n  commit_gate: none' WRAP_COMMIT_GATE)"
  assert_eq "make lint" "$(_var $'wrap:\n  commit_gate: make lint' WRAP_COMMIT_GATE)"
}
