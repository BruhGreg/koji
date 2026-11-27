#!/usr/bin/env bash
# tests/cases/tree-snapshot.sh — koji-tree-snapshot: a review bound to a tree object.
#
# The contract: `same` passes only when the staged-everything tree AND HEAD equal
# the captured record; a missing or garbled record never passes; `stale` latches.

SNAP="$KOJI/bin/koji-tree-snapshot"

_mkrepo() {   # a scratch repo with one commit; gpgsign forced off
  local d="$TMP/$1"
  rm -rf "$d"; mkdir -p "$d"
  git -C "$d" -c init.defaultBranch=main init -q
  git -C "$d" config user.email "koji@test.local"
  git -C "$d" config user.name "Koji Test"
  printf 'hello\n' > "$d/a.txt"
  git -C "$d" add a.txt
  git -C "$d" -c commit.gpgsign=false commit -q -m init
  printf '%s' "$d"
}

_same() {   # _same <repo> <record> → RC
  RC=0; ( cd "$1" && "$SNAP" same "$2" ) 2>"$TMP/snap.err" || RC=$?
}

test_capture_then_same_is_0() {
  local d; d="$(_mkrepo cap)"
  local t; t="$( cd "$d" && "$SNAP" capture "$TMP/cap.tree" )"
  assert_eq "$(git -C "$d" write-tree)" "$t" "prints the tree id"
  _same "$d" "$TMP/cap.tree"
  assert_exit 0 "$RC" "nothing moved"
}

test_capture_stages_untracked_files() {
  local d; d="$(_mkrepo untracked)"
  printf 'new\n' > "$d/new.txt"
  local t; t="$( cd "$d" && "$SNAP" capture "$TMP/u.tree" )"
  git -C "$d" ls-tree --name-only "$t" | grep -qx 'new.txt' && _ok || _fail "the untracked file is in the tree"
  git -C "$d" diff HEAD "$t" -- | grep -q '^+new$' && _ok || _fail "a diff from the tree object shows the new file"
}

test_an_edit_or_a_new_file_moves_it() {
  local d; d="$(_mkrepo edit)"
  ( cd "$d" && "$SNAP" capture "$TMP/e.tree" ) >/dev/null
  printf 'more\n' >> "$d/a.txt"
  _same "$d" "$TMP/e.tree"
  assert_exit 1 "$RC" "a tracked edit"
  assert_file_contains "the tree moved" "$TMP/snap.err"
  ( cd "$d" && "$SNAP" capture "$TMP/e.tree" ) >/dev/null
  printf 'x\n' > "$d/other.txt"
  _same "$d" "$TMP/e.tree"
  assert_exit 1 "$RC" "a new untracked file"
}

test_a_commit_moves_it_even_with_the_same_tree() {
  local d; d="$(_mkrepo commit)"
  printf 'more\n' >> "$d/a.txt"
  ( cd "$d" && "$SNAP" capture "$TMP/c.tree" ) >/dev/null
  git -C "$d" -c commit.gpgsign=false commit -qam "by the reviewer"
  _same "$d" "$TMP/c.tree"
  assert_exit 1 "$RC" "HEAD moved"
  assert_file_contains "HEAD moved" "$TMP/snap.err"
}

test_a_missing_or_garbled_record_never_passes() {
  local d; d="$(_mkrepo garbled)"
  _same "$d" "$TMP/no-such.tree"
  assert_exit 3 "$RC" "missing"
  : > "$TMP/empty.tree"; _same "$d" "$TMP/empty.tree"
  assert_exit 3 "$RC" "empty"
  printf 'not-a-tree abc\n' > "$TMP/bad.tree"; _same "$d" "$TMP/bad.tree"
  assert_exit 3 "$RC" "garbled"
  printf '%s' "$(git -C "$d" write-tree)" > "$TMP/half.tree"; _same "$d" "$TMP/half.tree"
  assert_exit 3 "$RC" "a record with no HEAD field"
}

test_a_record_with_no_trailing_newline_reads() {
  local d; d="$(_mkrepo nonl)"
  printf '%s %s' "$(git -C "$d" write-tree)" "$(git -C "$d" rev-parse HEAD)" > "$TMP/nonl.tree"
  _same "$d" "$TMP/nonl.tree"
  assert_exit 0 "$RC"
}

test_outside_a_repo_capture_fails_and_same_is_4() {
  local d="$TMP/plain"; rm -rf "$d"; mkdir -p "$d"
  local rc=0; ( cd "$d" && GIT_CEILING_DIRECTORIES="$TMP" "$SNAP" capture "$TMP/p.tree" ) >/dev/null 2>&1 || rc=$?
  assert_exit 1 "$rc" "capture"
  printf '%s unborn\n' "4b825dc642cb6eb9a060e54bf8d69288fbee4904" > "$TMP/p.tree"
  rc=0; ( cd "$d" && GIT_CEILING_DIRECTORIES="$TMP" "$SNAP" same "$TMP/p.tree" ) >/dev/null 2>&1 || rc=$?
  assert_exit 4 "$rc" "same"
}

test_stale_is_silent_outside_an_embedded_run() {
  local d; d="$(_mkrepo standalone)"
  local run="$TMP/run-standalone"; rm -rf "$run"; mkdir -p "$run"
  printf 'edit\n' >> "$d/a.txt"
  assert_eq "" "$( cd "$d" && "$SNAP" stale "$run" 2>/dev/null )" "no embedded marker: never stages, never stale"
  git -C "$d" diff --cached --quiet && _ok || _fail "a standalone check staged the tree"
}

test_stale_latches() {
  local d; d="$(_mkrepo latch)"
  local run="$TMP/run-latch"; rm -rf "$run"; mkdir -p "$run"
  : > "$run/embedded"
  ( cd "$d" && "$SNAP" capture "$run/review.tree" ) >/dev/null
  assert_eq "" "$( cd "$d" && "$SNAP" stale "$run" 2>/dev/null )" "unchanged: not stale"
  printf 'edit\n' >> "$d/a.txt"
  assert_eq 1 "$( cd "$d" && "$SNAP" stale "$run" 2>/dev/null )" "moved: stale"
  [ -e "$run/snapshot.stale" ] && _ok || _fail "the latch file exists"
  git -C "$d" checkout -q -- a.txt 2>/dev/null; git -C "$d" reset -q --hard
  assert_eq 1 "$( cd "$d" && "$SNAP" stale "$run" 2>/dev/null )" "moved back: still stale (latched)"
}

test_stale_with_a_lost_record_is_stale() {
  local d; d="$(_mkrepo lost)"
  local run="$TMP/run-lost"; rm -rf "$run"; mkdir -p "$run"
  : > "$run/embedded"
  assert_eq 1 "$( cd "$d" && "$SNAP" stale "$run" 2>/dev/null )" "embedded, no review.tree: fail closed"
}

test_usage_errors_are_2() {
  local rc=0; "$SNAP" >/dev/null 2>&1 || rc=$?
  assert_exit 2 "$rc" "no mode"
  rc=0; "$SNAP" same >/dev/null 2>&1 || rc=$?
  assert_exit 2 "$rc" "no record"
  rc=0; "$SNAP" stale "$TMP/not-a-dir" >/dev/null 2>&1 || rc=$?
  assert_exit 2 "$rc" "stale needs a directory"
}

test_capture_never_touches_the_real_index() {
  # It stages into a temporary copy: your staging, and untracked files, stay as they were.
  local d; d="$(_mkrepo realindex)"
  printf 'new\n' > "$d/new.txt"; printf 'edit\n' >> "$d/a.txt"
  ( cd "$d" && "$SNAP" capture "$TMP/ri.tree" ) >/dev/null
  git -C "$d" diff --cached --quiet && _ok || _fail "capture staged something in the real index"
  assert_contains "?? new.txt" "$(git -C "$d" status --porcelain)" "the new file is still untracked"
  _same "$d" "$TMP/ri.tree"
  assert_exit 0 "$RC" "same agrees without staging anything either"
}

test_a_held_index_lock_does_not_fail_it() {
  # Another git process (an IDE, a status line) holding .git/index.lock used to
  # fail capture and, in stale mode, latch a full final review to REJECT.
  local d; d="$(_mkrepo lock)"
  : > "$d/.git/index.lock"
  local rc=0; ( cd "$d" && "$SNAP" capture "$TMP/lk.tree" ) >/dev/null 2>&1 || rc=$?
  assert_exit 0 "$rc" "capture with a held lock"
  _same "$d" "$TMP/lk.tree"
  assert_exit 0 "$RC" "same with a held lock"
  [ -e "$d/.git/index.lock" ] && _ok || _fail "the other process's lock was removed"
  rm -f "$d/.git/index.lock"
}

test_no_index_yet_still_captures() {
  # A checkout with no index (clone --no-checkout, or a deleted index): the
  # temporary index starts empty instead of as an invalid 0-byte file.
  local d; d="$(_mkrepo noindex)"
  rm -f "$d/.git/index"
  local t rc=0; t="$( cd "$d" && "$SNAP" capture "$TMP/ni.tree" )" || rc=$?
  assert_exit 0 "$rc" "capture with no index"
  assert_eq "$(git -C "$d" rev-parse 'HEAD^{tree}')" "$t" "the tree of an unchanged checkout is HEAD's tree"
}

test_a_latched_run_is_not_checked_again() {
  local d; d="$(_mkrepo latched)"
  local run="$TMP/run-latched"; rm -rf "$run"; mkdir -p "$run"
  : > "$run/embedded"; : > "$run/snapshot.stale"
  assert_eq 1 "$( cd "$d" && "$SNAP" stale "$run" 2>"$TMP/lt.err" )" "latched: stale"
  assert_file_not_contains "tree changed" "$TMP/lt.err" "no second check, no second warning"
}

test_a_failed_capture_says_why() {
  # git's own reason, so the cause is fixable: a nested repo with no commit.
  local d; d="$(_mkrepo nested)"
  mkdir -p "$d/sub"; git -C "$d/sub" init -q; printf 'x\n' > "$d/sub/f"
  local rc=0; ( cd "$d" && "$SNAP" capture "$TMP/nested.tree" ) >/dev/null 2>"$TMP/nested.err" || rc=$?
  assert_exit 1 "$rc" "capture fails"
  assert_file_contains "koji-tree-snapshot: git:" "$TMP/nested.err" "git's reason is shown"
}

test_stale_with_no_record_says_cannot_compare() {
  local d; d="$(_mkrepo nocompare)"
  local run="$TMP/run-nocompare"; rm -rf "$run"; mkdir -p "$run"; : > "$run/embedded"
  ( cd "$d" && "$SNAP" stale "$run" ) >/dev/null 2>"$TMP/nc.err"
  assert_file_contains "cannot compare" "$TMP/nc.err"
  assert_file_not_contains "the tree changed" "$TMP/nc.err"
}
