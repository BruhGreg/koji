#!/usr/bin/env bash
# tests/cases/amendable.sh — koji-amendable's verdict and its REASON ordering.
#
# Every case builds a throwaway repo under $TMP. Identity is set with `git
# config` INSIDE each repo (not only with `git -c`) because the script compares
# HEAD's committer against `git config user.email`, which has to read back.
# gpgsign is forced off so a machine that signs by default still passes.

AM="$KOJI/bin/koji-amendable"

_git() { git -C "$REPO" -c commit.gpgsign=false "$@"; }

# $1 = repo name. Sets $REPO. One commit, one branch, identity configured.
_mkrepo() {
  REPO="$TMP/$1"
  mkdir -p "$REPO"
  git -C "$REPO" -c init.defaultBranch=main init -q
  git -C "$REPO" config user.email "koji@test.local"
  git -C "$REPO" config user.name "Koji Test"
  printf 'one\n' >"$REPO/a.txt"
  _git add a.txt
  _git commit -q -m "first commit"
}

# $1 = file name, $2 = message, rest = extra `git -c` overrides.
_commit() {
  local f="$1" msg="$2"; shift 2
  printf '%s\n' "$msg" >>"$REPO/$f"
  _git add "$f"
  git -C "$REPO" -c commit.gpgsign=false "$@" commit -q -m "$msg"
}

# Write the session sentinel (content = the session's starting rev).
_sentinel() {
  SENTINEL="$TMP/$(basename "$REPO").start"
  printf '%s\n' "$1" >"$SENTINEL"
}

_run() { ( cd "$REPO" && SESSION_START_FILE="${1:-$SENTINEL}" "$AM" ); }

# Pull one emitted field out of the sourceable output.
_field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

test_fresh_session_commit_is_amendable() {
  _mkrepo amendable
  _sentinel "$(_git rev-parse HEAD)"
  sleep 1                       # commit times are whole seconds; the sentinel
  _commit b.txt "second commit" # file's mtime must be strictly older
  local out; out="$(_run)"
  assert_eq "true" "$(_field "$out" AMENDABLE)" "verdict"
  assert_eq "ok"   "$(_field "$out" REASON)"    "reason"
}

# The emitted block must survive `eval` intact, including a subject full of
# quotes and spaces — that is the whole reason for printf %q.
test_output_is_sourceable() {
  _mkrepo sourceable
  _sentinel "$(_git rev-parse HEAD)"
  sleep 1
  _commit b.txt "fix: it's \"quoted\" & spaced"
  local out; out="$(_run)"
  local subject age
  subject="$( eval "$out"; printf '%s' "$HEAD_SUBJECT" )"
  age="$( eval "$out"; printf '%s' "$HEAD_AGE_SECONDS" )"
  assert_eq "fix: it's \"quoted\" & spaced" "$subject" "HEAD_SUBJECT round-trips"
  case "$age" in
    ''|*[!0-9]*) _fail "HEAD_AGE_SECONDS not an integer: [$age]" ;;
    *)           _ok ;;
  esac
}

test_missing_sentinel() {
  _mkrepo nosentinel
  local out; out="$(_run "$TMP/does-not-exist")"
  assert_eq "false"       "$(_field "$out" AMENDABLE)"
  assert_eq "no-sentinel" "$(_field "$out" REASON)"
}

test_garbage_sentinel_rev() {
  _mkrepo garbage
  _sentinel "not-a-rev"
  local out; out="$(_run)"
  assert_eq "no-sentinel" "$(_field "$out" REASON)" "unparseable rev"
}

test_detached_head() {
  _mkrepo detached
  _sentinel "$(_git rev-parse HEAD)"
  _commit b.txt "second commit"
  _git checkout -q --detach HEAD
  local out; out="$(_run)"
  assert_eq "false"    "$(_field "$out" AMENDABLE)"
  assert_eq "detached" "$(_field "$out" REASON)"
}

test_merge_commit() {
  _mkrepo merge
  _sentinel "$(_git rev-parse HEAD)"
  local base; base="$(_git symbolic-ref --short HEAD)"
  _git checkout -q -b feature
  _commit f.txt "feature commit"
  _git checkout -q "$base"
  _commit m.txt "main commit"
  _git merge -q --no-ff -m "merge feature" feature
  local out; out="$(_run)"
  assert_eq "false"        "$(_field "$out" AMENDABLE)"
  assert_eq "merge-commit" "$(_field "$out" REASON)"
}

# HEAD is the root commit: there is nothing underneath to amend onto. Checked
# before the HEAD-vs-sentinel comparison, so this wins over no-session-commits.
test_root_commit() {
  _mkrepo root
  _sentinel "$(_git rev-parse HEAD)"
  local out; out="$(_run)"
  assert_eq "root-commit" "$(_field "$out" REASON)"
}

test_no_session_commits() {
  _mkrepo nosession
  _commit b.txt "second commit"
  _sentinel "$(_git rev-parse HEAD)"   # sentinel == HEAD, and HEAD has a parent
  local out; out="$(_run)"
  assert_eq "false"              "$(_field "$out" AMENDABLE)"
  assert_eq "no-session-commits" "$(_field "$out" REASON)"
}

# Sentinel points at a commit that is not in HEAD's history (branch switch /
# rebase since kick-off).
test_sentinel_not_ancestor() {
  _mkrepo notancestor
  local base; base="$(_git symbolic-ref --short HEAD)"
  _git checkout -q -b sidebranch
  _commit s.txt "side commit"
  _sentinel "$(_git rev-parse HEAD)"
  _git checkout -q "$base"
  _commit m.txt "main commit"
  local out; out="$(_run)"
  assert_eq "false"                 "$(_field "$out" AMENDABLE)"
  assert_eq "sentinel-not-ancestor" "$(_field "$out" REASON)"
}

test_other_author() {
  _mkrepo otherauthor
  _sentinel "$(_git rev-parse HEAD)"
  sleep 1
  _commit b.txt "someone else's commit" \
    -c user.email=someone@example.com -c user.name="Someone Else"
  local out; out="$(_run)"
  assert_eq "false"        "$(_field "$out" AMENDABLE)"
  assert_eq "other-author" "$(_field "$out" REASON)"
}

# Sentinel touched AFTER the commit — i.e. the commit predates this session.
test_older_than_session() {
  _mkrepo oldcommit
  _sentinel "$(_git rev-parse HEAD)"
  _commit b.txt "second commit"
  sleep 1
  touch "$SENTINEL"
  local out; out="$(_run)"
  assert_eq "false"               "$(_field "$out" AMENDABLE)"
  assert_eq "older-than-session"  "$(_field "$out" REASON)"
}

test_pushed_commit() {
  _mkrepo pushed
  _sentinel "$(_git rev-parse HEAD)"
  sleep 1
  _commit b.txt "second commit"
  git -c init.defaultBranch=main init -q --bare "$TMP/remote.git"
  _git remote add origin "$TMP/remote.git"
  _git push -q -u origin "$(_git symbolic-ref --short HEAD)"
  local out; out="$(_run)"
  assert_eq "false"  "$(_field "$out" AMENDABLE)"
  assert_eq "pushed" "$(_field "$out" REASON)"
}

test_outside_a_git_repo() {
  local d="$TMP/plain"
  mkdir -p "$d"
  local out; out="$( cd "$d" && SESSION_START_FILE="$TMP/none" "$AM" )"
  assert_eq "false" "$(_field "$out" AMENDABLE)"
  assert_eq "nogit" "$(_field "$out" REASON)"
}

test_upstream_configured_but_head_ahead_is_amendable() {
  _mkrepo ahead
  local remote="$TMP/ahead-remote.git"
  git init -q --bare "$remote"
  _git remote add origin "$remote"
  _git push -q -u origin main 2>/dev/null
  _sentinel "$(_git rev-parse HEAD)"
  sleep 1
  _commit a.txt "local work not yet pushed"
  eval "$(_run)"
  assert_eq true "$AMENDABLE" "HEAD ahead of @{u} is not known pushed"
  assert_eq ok "$REASON"
}
