# koji-permission-mode: effective defaultMode resolution + inert project keys.
# All inputs come from fixture files under $TMP via the KOJI_* env overrides.

PM="$KOJI/bin/koji-permission-mode"

_root() {   # _root <name> → fresh settings root with .claude/
  local r="$TMP/root-$1"; mkdir -p "$r/.claude"; printf '%s' "$r"
}
_json() {   # _json <file> <json text>
  mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"
}
_pm() {     # _pm <root> <user-file> <managed-dir> <version> [VAR] → sourced VAR (or all output)
  local out
  out="$(KOJI_SETTINGS_ROOT="$1" KOJI_USER_SETTINGS="$2" KOJI_MANAGED_DIR="$3" KOJI_CLAUDE_VERSION="$4" "$PM" 2>"$TMP/pm.err")"
  if [ -n "${5:-}" ]; then ( eval "$out"; eval "printf '%s' \"\${$5:-}\"" ); else printf '%s' "$out"; fi
}

EMPTY_MANAGED="$TMP/managed-empty"; mkdir -p "$EMPTY_MANAGED"
NO_USER="$TMP/no-user.json"   # deliberately absent

test_user_bypass_clean_project_short_circuits() {
  local r; r="$(_root a)"
  _json "$TMP/user-a.json" '{"permissions": {"defaultMode": "bypassPermissions", "allow": ["Read"]}}'
  _json "$r/.claude/settings.json" '{"permissions": {"allow": ["Bash(git status:*)"]}}'
  assert_eq true   "$(_pm "$r" "$TMP/user-a.json" "$EMPTY_MANAGED" 2.1.259 EFFECTIVE_BYPASS)"
  assert_eq user   "$(_pm "$r" "$TMP/user-a.json" "$EMPTY_MANAGED" 2.1.259 MODE_SOURCE)"
  assert_eq ""     "$(_pm "$r" "$TMP/user-a.json" "$EMPTY_MANAGED" 2.1.259 INERT_LOCAL_MODE)"
}

test_local_default_overrides_user_bypass() {
  local r; r="$(_root b)"
  _json "$TMP/user-b.json" '{"permissions": {"defaultMode": "bypassPermissions"}}'
  _json "$r/.claude/settings.local.json" '{"permissions": {"defaultMode": "default"}}'
  assert_eq false   "$(_pm "$r" "$TMP/user-b.json" "$EMPTY_MANAGED" 2.1.259 EFFECTIVE_BYPASS)"
  assert_eq local   "$(_pm "$r" "$TMP/user-b.json" "$EMPTY_MANAGED" 2.1.259 MODE_SOURCE)"
  assert_eq default "$(_pm "$r" "$TMP/user-b.json" "$EMPTY_MANAGED" 2.1.259 EFFECTIVE_MODE)"
}

test_stale_local_mirror_is_inert_not_effective() {
  local r; r="$(_root c)"
  _json "$r/.claude/settings.local.json" '{"permissions": {"defaultMode": "bypassPermissions", "allow": ["Bash(ls:*)"]}}'
  assert_eq false "$(_pm "$r" "$NO_USER" "$EMPTY_MANAGED" 2.1.259 EFFECTIVE_BYPASS)" "the request's bug"
  assert_eq bypassPermissions "$(_pm "$r" "$NO_USER" "$EMPTY_MANAGED" 2.1.259 INERT_LOCAL_MODE)"
  assert_eq default "$(_pm "$r" "$NO_USER" "$EMPTY_MANAGED" 2.1.259 MODE_SOURCE)"
}

test_both_project_files_stale_both_reported() {
  local r; r="$(_root d)"
  _json "$r/.claude/settings.local.json" '{"permissions": {"defaultMode": "bypassPermissions"}}'
  _json "$r/.claude/settings.json" '{"permissions": {"defaultMode": "auto"}}'
  assert_eq bypassPermissions "$(_pm "$r" "$NO_USER" "$EMPTY_MANAGED" 2.1.259 INERT_LOCAL_MODE)"
  assert_eq auto              "$(_pm "$r" "$NO_USER" "$EMPTY_MANAGED" 2.1.259 INERT_PROJECT_MODE)"
}

test_disable_key_defeats_user_bypass() {
  local r; r="$(_root e)"
  _json "$TMP/user-e.json" '{"permissions": {"defaultMode": "bypassPermissions", "disableBypassPermissionsMode": "disable"}}'
  assert_eq false    "$(_pm "$r" "$TMP/user-e.json" "$EMPTY_MANAGED" 2.1.259 EFFECTIVE_BYPASS)"
  assert_eq disabled "$(_pm "$r" "$TMP/user-e.json" "$EMPTY_MANAGED" 2.1.259 MODE_SOURCE)"
}

test_legacy_version_honors_project_bypass() {
  local r; r="$(_root f)"
  _json "$r/.claude/settings.local.json" '{"permissions": {"defaultMode": "bypassPermissions"}}'
  assert_eq true "$(_pm "$r" "$NO_USER" "$EMPTY_MANAGED" 2.1.250 EFFECTIVE_BYPASS)"
  assert_eq project-legacy "$(_pm "$r" "$NO_USER" "$EMPTY_MANAGED" 2.1.250 MODE_SOURCE)"
  assert_eq "" "$(_pm "$r" "$NO_USER" "$EMPTY_MANAGED" 2.1.250 INERT_LOCAL_MODE)"
}

test_unknown_version_treated_as_current() {
  local r; r="$(_root g)"
  _json "$r/.claude/settings.local.json" '{"permissions": {"defaultMode": "bypassPermissions"}}'
  assert_eq false   "$(_pm "$r" "$NO_USER" "$EMPTY_MANAGED" unknown EFFECTIVE_BYPASS)"
  assert_eq unknown "$(_pm "$r" "$NO_USER" "$EMPTY_MANAGED" unknown CLAUDE_VERSION)"
}

test_managed_dropin_beats_base_and_everything_else() {
  local r m; r="$(_root h)"; m="$TMP/managed-h"
  _json "$m/managed-settings.json" '{"permissions": {"defaultMode": "bypassPermissions"}}'
  _json "$m/managed-settings.d/10-policy.json" '{"permissions": {"defaultMode": "acceptEdits"}}'
  _json "$TMP/user-h.json" '{"permissions": {"defaultMode": "bypassPermissions"}}'
  assert_eq acceptEdits "$(_pm "$r" "$TMP/user-h.json" "$m" 2.1.259 EFFECTIVE_MODE)"
  assert_eq managed     "$(_pm "$r" "$TMP/user-h.json" "$m" 2.1.259 MODE_SOURCE)"
  assert_eq false       "$(_pm "$r" "$TMP/user-h.json" "$m" 2.1.259 EFFECTIVE_BYPASS)"
}

test_malformed_json_is_treated_as_unset() {
  local r; r="$(_root i)"
  printf '{not json' > "$r/.claude/settings.local.json"
  _json "$TMP/user-i.json" '{"permissions": {"defaultMode": "bypassPermissions"}}'
  assert_eq true "$(_pm "$r" "$TMP/user-i.json" "$EMPTY_MANAGED" 2.1.259 EFFECTIVE_BYPASS)"
}

test_remove_inert_is_atomic_and_idempotent() {
  local r out; r="$(_root j)"
  _json "$r/.claude/settings.local.json" '{"permissions": {"defaultMode": "bypassPermissions", "allow": ["Bash(ls:*)"]}, "other": 1}'
  _json "$r/.claude/settings.json" '{"permissions": {"defaultMode": "acceptEdits"}}'
  out="$(KOJI_SETTINGS_ROOT="$r" KOJI_USER_SETTINGS="$NO_USER" KOJI_MANAGED_DIR="$EMPTY_MANAGED" KOJI_CLAUDE_VERSION=2.1.259 "$PM" --remove-inert)"
  assert_contains "removed inert" "$out"
  assert_contains "settings.local.json" "$out"
  assert_file_not_contains defaultMode "$r/.claude/settings.local.json" "key removed"
  assert_file_contains 'Bash(ls:*)' "$r/.claude/settings.local.json" "sibling keys preserved"
  assert_file_contains '"other": 1' "$r/.claude/settings.local.json"
  assert_file_contains acceptEdits "$r/.claude/settings.json" "non-inert project value untouched"
  out="$(KOJI_SETTINGS_ROOT="$r" KOJI_USER_SETTINGS="$NO_USER" KOJI_MANAGED_DIR="$EMPTY_MANAGED" KOJI_CLAUDE_VERSION=2.1.259 "$PM" --remove-inert)"
  assert_eq "nothing to remove" "$out" "second run is a no-op"
  assert_eq 0 "$(ls "$r/.claude" | grep -c '\.tmp$' || true)" "no temp files left"
}

test_worktree_resolves_to_main_checkout() {
  command -v git >/dev/null || return 0
  local main="$TMP/wt-main" wt="$TMP/wt-branch" got
  mkdir -p "$main" && (cd "$main" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init) || return 0
  (cd "$main" && git worktree add -q "$wt" -b side) || return 0
  mkdir -p "$main/.claude"
  _json "$main/.claude/settings.local.json" '{"permissions": {"defaultMode": "bypassPermissions"}}'
  got="$(cd "$wt" && KOJI_USER_SETTINGS="$NO_USER" KOJI_MANAGED_DIR="$EMPTY_MANAGED" KOJI_CLAUDE_VERSION=2.1.259 "$PM")"
  assert_eq "$(cd "$main" && pwd -P)" "$( eval "$got"; printf '%s' "$SETTINGS_ROOT" )" "SETTINGS_ROOT is the main checkout"
  assert_eq bypassPermissions "$( eval "$got"; printf '%s' "$INERT_LOCAL_MODE" )" "main checkout's local file was read"
}

test_always_marks_approximate() {
  local r; r="$(_root k)"
  assert_eq true "$(_pm "$r" "$NO_USER" "$EMPTY_MANAGED" 2.1.259 APPROXIMATE)"
}

test_disable_auto_mode_key() {
  local r; r="$(_root l)"
  _json "$TMP/user-l.json" '{"permissions": {"defaultMode": "auto", "disableAutoMode": "disable"}}'
  assert_eq default  "$(_pm "$r" "$TMP/user-l.json" "$EMPTY_MANAGED" 2.1.259 EFFECTIVE_MODE)"
  assert_eq disabled "$(_pm "$r" "$TMP/user-l.json" "$EMPTY_MANAGED" 2.1.259 MODE_SOURCE)"
}

test_effective_auto_does_not_count_as_bypass() {
  local r; r="$(_root m)"
  _json "$TMP/user-m.json" '{"permissions": {"defaultMode": "auto"}}'
  assert_eq auto  "$(_pm "$r" "$TMP/user-m.json" "$EMPTY_MANAGED" 2.1.259 EFFECTIVE_MODE)"
  assert_eq false "$(_pm "$r" "$TMP/user-m.json" "$EMPTY_MANAGED" 2.1.259 EFFECTIVE_BYPASS)" "Decision 7: auto never short-circuits"
}

test_non_inert_project_value_is_effective() {
  local r; r="$(_root n)"
  _json "$r/.claude/settings.json" '{"permissions": {"defaultMode": "plan"}}'
  _json "$TMP/user-n.json" '{"permissions": {"defaultMode": "bypassPermissions"}}'
  assert_eq plan    "$(_pm "$r" "$TMP/user-n.json" "$EMPTY_MANAGED" 2.1.259 EFFECTIVE_MODE)"
  assert_eq project "$(_pm "$r" "$TMP/user-n.json" "$EMPTY_MANAGED" 2.1.259 MODE_SOURCE)"
  assert_eq ""      "$(_pm "$r" "$TMP/user-n.json" "$EMPTY_MANAGED" 2.1.259 INERT_PROJECT_MODE)" "plan is not inert"
}

test_inert_project_key_reported_even_when_local_default_wins() {
  local r out; r="$(_root o)"
  _json "$r/.claude/settings.local.json" '{"permissions": {"defaultMode": "default"}}'
  _json "$r/.claude/settings.json" '{"permissions": {"defaultMode": "bypassPermissions"}}'
  assert_eq local "$(_pm "$r" "$NO_USER" "$EMPTY_MANAGED" 2.1.259 MODE_SOURCE)"
  assert_eq bypassPermissions "$(_pm "$r" "$NO_USER" "$EMPTY_MANAGED" 2.1.259 INERT_PROJECT_MODE)" "shadowed inert key still reported"
  out="$(KOJI_SETTINGS_ROOT="$r" KOJI_USER_SETTINGS="$NO_USER" KOJI_MANAGED_DIR="$EMPTY_MANAGED" KOJI_CLAUDE_VERSION=2.1.259 "$PM" --remove-inert)"
  assert_contains "settings.json" "$out" "and removed"
  assert_file_not_contains defaultMode "$r/.claude/settings.json"
  assert_file_contains '"default"' "$r/.claude/settings.local.json" "local default untouched"
}

test_version_boundary_2_1_257_is_current() {
  local r; r="$(_root p)"
  _json "$r/.claude/settings.local.json" '{"permissions": {"defaultMode": "bypassPermissions"}}'
  assert_eq false "$(_pm "$r" "$NO_USER" "$EMPTY_MANAGED" 2.1.257 EFFECTIVE_BYPASS)" "2.1.257 itself is current"
  assert_eq true  "$(_pm "$r" "$NO_USER" "$EMPTY_MANAGED" 2.1.256 EFFECTIVE_BYPASS)" "2.1.256 is legacy"
}

test_submodule_root_is_the_submodule_checkout() {
  command -v git >/dev/null || return 0
  local sup="$TMP/sm-super" sub="$TMP/sm-sub" got
  mkdir -p "$sub" && (cd "$sub" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init) || return 0
  mkdir -p "$sup" && (cd "$sup" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
    && git -c protocol.file.allow=always submodule add -q "$sub" child >/dev/null 2>&1) || return 0
  [ -d "$sup/child/.git" ] || [ -f "$sup/child/.git" ] || return 0
  mkdir -p "$sup/child/.claude"
  _json "$sup/child/.claude/settings.local.json" '{"permissions": {"defaultMode": "bypassPermissions"}}'
  got="$(cd "$sup/child" && KOJI_USER_SETTINGS="$NO_USER" KOJI_MANAGED_DIR="$EMPTY_MANAGED" KOJI_CLAUDE_VERSION=2.1.259 "$PM")"
  assert_eq "$(cd "$sup/child" && pwd -P)" "$( eval "$got"; printf '%s' "$SETTINGS_ROOT" )" "submodule keeps its own root"
  assert_eq bypassPermissions "$( eval "$got"; printf '%s' "$INERT_LOCAL_MODE" )"
}
