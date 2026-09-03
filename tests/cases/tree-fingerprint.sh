#!/usr/bin/env bash
# tests/cases/tree-fingerprint.sh — koji-tree-fingerprint.
#
# The contract under test: the digest moves when the tree's CONTENT moves, and
# only then — and `--cached` moves only when the staged set moves.

FP="$KOJI/bin/koji-tree-fingerprint"

# A scratch repo with one commit. gpgsign is forced off so the suite still
# passes on a machine whose global gitconfig signs every commit.
_mkrepo() {
  local d="$TMP/$1"
  mkdir -p "$d"
  git -C "$d" -c init.defaultBranch=main init -q
  git -C "$d" config user.email "koji@test.local"
  git -C "$d" config user.name "Koji Test"
  printf 'hello\n' >"$d/a.txt"
  git -C "$d" add a.txt
  git -C "$d" -c commit.gpgsign=false commit -q -m "init"
  printf '%s' "$d"
}

_fp() { ( cd "$1" && "$FP" ); }

test_deterministic_on_unchanged_tree() {
  local d; d="$(_mkrepo det)"
  local a b
  a="$(_fp "$d")"
  b="$(_fp "$d")"
  assert_eq "$a" "$b" "two runs, unchanged tree"
  assert_ne "" "$a" "digest is non-empty"
  assert_ne "nogit" "$a" "digest is not the no-repo token"
}

test_tracked_edit_moves_default_not_cached() {
  local d; d="$(_mkrepo edit)"
  local before before_cached after after_cached
  before="$(_fp "$d")"
  before_cached="$( cd "$d" && "$FP" --cached )"
  printf 'changed\n' >>"$d/a.txt"
  after="$(_fp "$d")"
  after_cached="$( cd "$d" && "$FP" --cached )"
  assert_ne "$before" "$after"               "unstaged edit moves the default digest"
  assert_eq "$before_cached" "$after_cached" "unstaged edit leaves --cached alone"
}

test_staging_moves_cached() {
  local d; d="$(_mkrepo stage)"
  printf 'changed\n' >>"$d/a.txt"
  local before_cached after_cached
  before_cached="$( cd "$d" && "$FP" --cached )"
  git -C "$d" add a.txt
  after_cached="$( cd "$d" && "$FP" --cached )"
  assert_ne "$before_cached" "$after_cached" "git add moves --cached"
}

test_untracked_file_moves_default_not_cached() {
  local d; d="$(_mkrepo untracked)"
  local before before_cached after after_cached
  before="$(_fp "$d")"
  before_cached="$( cd "$d" && "$FP" --cached )"
  printf 'new file\n' >"$d/b.txt"
  after="$(_fp "$d")"
  after_cached="$( cd "$d" && "$FP" --cached )"
  assert_ne "$before" "$after"               "untracked file moves the default digest"
  assert_eq "$before_cached" "$after_cached" "untracked file leaves --cached alone"
}

# Ignored files must not move it — otherwise every build artifact would look
# like a reviewer writing to the tree.
test_ignored_file_does_not_move_digest() {
  local d; d="$(_mkrepo ignored)"
  printf 'junk/\n' >"$d/.gitignore"
  git -C "$d" add .gitignore
  git -C "$d" -c commit.gpgsign=false commit -q -m "ignore junk"
  local before after
  before="$(_fp "$d")"
  mkdir -p "$d/junk"
  printf 'build output\n' >"$d/junk/out.o"
  after="$(_fp "$d")"
  assert_eq "$before" "$after" "ignored file is invisible to the digest"
}

# Content, not metadata: `touch` alone must not move it.
test_touch_alone_does_not_move_digest() {
  local d; d="$(_mkrepo touched)"
  local before after
  before="$(_fp "$d")"
  touch "$d/a.txt"
  after="$(_fp "$d")"
  assert_eq "$before" "$after" "mtime bump is not a content change"
}

# Same repo, different cwd — the script resolves the toplevel itself.
test_digest_is_cwd_independent() {
  local d; d="$(_mkrepo cwd)"
  mkdir -p "$d/sub/deeper"
  printf 'tracked\n' >"$d/sub/c.txt"
  local top deep
  top="$(_fp "$d")"
  deep="$( cd "$d/sub/deeper" && "$FP" )"
  assert_eq "$top" "$deep" "digest does not depend on cwd"
}

test_non_repo_prints_nogit() {
  local d="$TMP/plain"
  mkdir -p "$d"
  local out rc=0
  out="$( cd "$d" && "$FP" )" || rc=$?
  assert_eq "nogit" "$out" "non-repo digest token"
  assert_exit 0 "$rc" "non-repo exit code"
}

test_unknown_option_is_usage_error() {
  local d; d="$(_mkrepo opt)"
  local rc=0
  ( cd "$d" && "$FP" --staged ) >/dev/null 2>&1 || rc=$?
  assert_exit 2 "$rc" "unknown flag"
}
