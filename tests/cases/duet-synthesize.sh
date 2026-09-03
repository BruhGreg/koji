#!/usr/bin/env bash
# tests/cases/duet-synthesize.sh — bin/koji-duet-synthesize backend provenance.
#
# `reviewers` and `agreed_by` carry SLOT identifiers (A/B) that downstream keys
# on, so they never change. `reviewer_backends` is the field that reports which
# model actually filled each slot.

SYNTH="$KOJI/bin/koji-duet-synthesize"

# Two minimal findings arrays: one shared fingerprint (consensus) + one solo
# each, so the synthesizer exercises a real merge rather than empty input.
_fixtures() {
  cat > "$TMP/claude.json" <<'JSON'
[
  {"file": "a.py", "line": 10, "category": "correctness", "severity": "medium",
   "title": "off-by-one", "detail": "loop overruns"},
  {"file": "b.py", "line": 3, "category": "style", "severity": "low",
   "title": "claude-only", "detail": "naming"}
]
JSON
  cat > "$TMP/codex.json" <<'JSON'
[
  {"file": "a.py", "line": 10, "category": "correctness", "severity": "medium",
   "title": "off-by-one", "detail": "loop overruns"},
  {"file": "c.py", "line": 7, "category": "security", "severity": "low",
   "title": "codex-only", "detail": "unescaped input"}
]
JSON
}

# _field <json-file> <python-expr over `d`> — echo one value from the verdict.
_field() {
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print($2)" "$1"
}

test_default_b_backend_is_codex() {
  _fixtures
  python3 "$SYNTH" --claude "$TMP/claude.json" --codex "$TMP/codex.json" \
    --out "$TMP/v-default.json" >/dev/null 2>&1
  assert_eq codex  "$(_field "$TMP/v-default.json" 'd["reviewer_backends"]["b"]')" "default b"
  assert_eq claude "$(_field "$TMP/v-default.json" 'd["reviewer_backends"]["a"]')" "slot a"
}

test_b_backend_claude_is_recorded() {
  _fixtures
  python3 "$SYNTH" --claude "$TMP/claude.json" --codex "$TMP/codex.json" \
    --out "$TMP/v-claude.json" --b-backend claude >/dev/null 2>&1
  assert_eq claude "$(_field "$TMP/v-claude.json" 'd["reviewer_backends"]["b"]')" "--b-backend claude"
  assert_eq claude "$(_field "$TMP/v-claude.json" 'd["reviewer_backends"]["a"]')" "slot a unchanged"
}

test_slot_identifiers_unchanged() {
  _fixtures
  python3 "$SYNTH" --claude "$TMP/claude.json" --codex "$TMP/codex.json" \
    --out "$TMP/v-slots.json" --b-backend claude >/dev/null 2>&1
  assert_eq 'claude,codex' \
    "$(_field "$TMP/v-slots.json" '",".join(d["reviewers"])')" "reviewers stay A/B slots"
  # The consensus finding still says agreed_by ["claude","codex"] — slot names.
  assert_eq 'claude,codex' \
    "$(_field "$TMP/v-slots.json" '",".join((d["medium"]+d["low"])[0]["agreed_by"])')" \
    "agreed_by stays A/B slots"
}

test_rejects_unknown_backend() {
  _fixtures
  python3 "$SYNTH" --claude "$TMP/claude.json" --codex "$TMP/codex.json" \
    --out "$TMP/v-bad.json" --b-backend gemini >/dev/null 2>&1
  assert_ne 0 "$?" "unknown --b-backend value is rejected"
}
