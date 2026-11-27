#!/usr/bin/env bash
# tests/cases/agy-dispatch.sh — koji-agy-exec, the agy (Antigravity CLI) adapter.
#
# tests/fixtures/fake-agy answers the free lookups and plays one stream-json
# scenario, so the adapter's contract is asserted without a real call: exit 0
# only for a real reply, 75 for every kind of "agy gave nothing usable", the
# model rule, the effort clamp, the bypass flags, and the tree fingerprint.

AGY_EXEC="$KOJI/bin/koji-agy-exec"
CLASSIFY="$KOJI/bin/koji-codex-classify"

# Harness markers would make every call here return 78 before the fake runs.
unset CODEX_THREAD_ID CODEX_SANDBOX ANTIGRAVITY_CONVERSATION_ID ANTIGRAVITY_TRAJECTORY_ID
export KOJI_STATE_DIR="$TMP/state"   # never read the user's real koji config

_setup() {
  rm -f "$TMP/state/config.yaml"   # bypass off unless a test opts in (_bypass_on)
  mkdir -p "$TMP/fake" "$TMP/rec"
  cp "$KOJI/tests/fixtures/fake-agy" "$TMP/fake/agy"; chmod +x "$TMP/fake/agy"
  rm -rf "$TMP/repo"; mkdir -p "$TMP/repo"
  ( cd "$TMP/repo" && git init -q && printf 'original\n' > existing.txt && git add . \
      && git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -qm init )
  rm -f "$TMP/rec/"*
  export FAKE_AGY_DIR="$TMP/rec"
  unset FAKE_AGY_MODE FAKE_AGY_MODEL FAKE_AGY_EFFORTS FAKE_AGY_USAGE FAKE_AGY_LOOKUP_FAIL FAKE_AGY_REPLY
  PATH_FAKE="$TMP/fake:$(_clean_sys_path)"
  printf 'REVIEW-PROMPT-HEAD\nReview the diff.\nREVIEW-PROMPT-TAIL\n' > "$TMP/prompt"
}

_run() {   # _run <effort> [VAR=value ...]  →  RC, $TMP/out, $TMP/err
  local eff="$1"; shift
  RC=0
  env "$@" PATH="$PATH_FAKE" "$AGY_EXEC" "${TIMEOUT_S:-30}" "$eff" "$TMP/repo" \
    < "$TMP/prompt" > "$TMP/out" 2> "$TMP/err" || RC=$?
}

_classify() {   # the state a collection site would see for the last _run
  echo "$RC" > "$TMP/exit"
  "$CLASSIFY" "$TMP/out" "$TMP/err" "$TMP/exit" "$@"
}

test_the_test_path_has_no_real_cli() {
  # Every assertion below depends on the FAKE agy answering. A real agy or codex
  # on this PATH would make the suite spend real calls and pass for the wrong reason.
  if PATH="$(_clean_sys_path)" command -v agy >/dev/null 2>&1 || PATH="$(_clean_sys_path)" command -v codex >/dev/null 2>&1; then
    _fail "a real agy/codex is on the system test PATH — the fakes cannot be trusted"
  else _ok; fi
}

# --- the happy path -------------------------------------------------------------
test_a_real_reply_passes_through() {
  _setup
  _run xhigh FAKE_AGY_REPLY='[{"severity":"low"}]'
  assert_exit 0 "$RC" "success"
  assert_eq '[{"severity":"low"}]' "$(cat "$TMP/out")" "stdout is exactly the response"
}

test_stream_flags_bypass_and_deny_rules() {
  _setup; _bypass_on
  _run high
  local argv; argv=$(cat "$TMP/rec/stream.argv")
  assert_contains "--input-format stream-json" "$argv" "stdin is stream-json"
  assert_contains "--output-format stream-json" "$argv" "stdout is stream-json"
  assert_contains "--dangerously-skip-permissions" "$argv" "bypass, the user's choice"
  assert_contains "--disable-slash-commands" "$argv" "a prompt can never run a slash command"
  assert_contains "--model gemini-4-neon " "$argv" "the BASE model is pinned (no effort suffix)"
  # The deny rules are one argv JSON object; parse it rather than grep it.
  local deny
  deny=$(python3 -c 'import json,re,sys
a = open(sys.argv[1]).read()
m = re.search(r"--settings (\{.*\}) --disable-slash-commands", a)
d = json.loads(m.group(1))["permissions"]["deny"]
print(" ".join(r for r in d if r in ("write_file(/)", "command(sh)", "command(bash)", "command(python3)", "command(gh)", "execute_url(*)", "mcp(*)")))' "$TMP/rec/stream.argv" 2>/dev/null)
  assert_eq "write_file(/) execute_url(*) mcp(*) command(sh) command(bash) command(python3) command(gh)" "$deny" "core deny rules present and valid JSON"
  assert_eq "$(cd "$TMP/repo" && pwd -P)" "$(cat "$TMP/rec/stream.cwd")" "agy runs in the project root"
}

test_prompt_is_one_ndjson_line_boundary_first_clause_last() {
  _setup
  _run xhigh
  local lines; lines=$(wc -l < "$TMP/rec/stream.stdin" | tr -d ' ')
  assert_eq 1 "$lines" "exactly one NDJSON message"
  python3 -c 'import json,sys
m = json.loads(open(sys.argv[1]).read())
assert m["event"] == "user"
t = m["message"]["content"]
b, h, c = t.find("filesystem scope"), t.find("REVIEW-PROMPT-HEAD"), t.find("Do not modify the repository")
assert 0 <= b < h < c, (b, h, c)
assert "REVIEW-PROMPT-TAIL" in t
# Task-neutral: the wrapper also carries votes and debate positions, so the
# clause must not say the task is a review; it says only what is blocked.
assert "REVIEWER" not in t and "review text" not in t
assert "Shell commands and web tools are not available in this session" in t   # bypass off: the default
assert "Reply with only the output the task above asks for" in t' "$TMP/rec/stream.stdin" && _ok || _fail "boundary → prompt → task-neutral guard clause"
}

test_a_large_prompt_arrives_intact() {
  _setup
  { printf 'BIG-HEAD\n'; printf 'x%.0s' $(seq 1 150000); printf '\nBIG-TAIL\n'; } > "$TMP/prompt"
  _run xhigh
  assert_exit 0 "$RC" "150 KB prompt"
  python3 -c 'import json,sys
t = json.loads(open(sys.argv[1]).read())["message"]["content"]
assert "BIG-HEAD" in t and "BIG-TAIL" in t and t.count("x") >= 150000' "$TMP/rec/stream.stdin" \
    && _ok || _fail "the whole prompt reached agy"
}

test_a_banner_line_before_the_stream_is_skipped() {
  _setup
  _run xhigh FAKE_AGY_MODE=banner
  assert_exit 0 "$RC" "non-JSON update notice on stdout"
  assert_eq "[]" "$(cat "$TMP/out")" "reply still found"
}

# --- effort clamp ---------------------------------------------------------------
test_max_clamps_to_xhigh_with_a_note() {
  _setup
  _run max
  assert_contains "--effort xhigh" "$(cat "$TMP/rec/stream.argv")" "max → xhigh on Neon"
  assert_file_contains "koji-note: agy runs gemini-4-neon at xhigh — max is not offered" "$TMP/err"
  assert_file_contains "koji-used: xhigh gemini-4-neon" "$TMP/err"
}

test_an_offered_effort_is_silent() {
  _setup
  _run high
  assert_contains "--effort high" "$(cat "$TMP/rec/stream.argv")" "high stays high"
  assert_file_not_contains "is not offered" "$TMP/err" "no note when nothing was clamped"
}

test_models_without_xhigh_clamp_to_high() {
  _setup
  _run max FAKE_AGY_MODEL=gemini-4-carbon-high FAKE_AGY_EFFORTS=low,medium,high
  assert_contains "--model gemini-4-carbon --effort high" "$(cat "$TMP/rec/stream.argv")" "max → high on Carbon"
}

test_a_failed_effort_lookup_never_fails_the_run() {
  _setup
  _run max FAKE_AGY_LOOKUP_FAIL=effort
  assert_exit 0 "$RC" "the run still happens"
  assert_not_contains "--effort" "$(cat "$TMP/rec/stream.argv")" "no --effort at all, not an empty one"
  assert_file_contains "default effort" "$TMP/err"
}

# --- the model rule: the outside voice is never Claude ----------------------------
test_non_gemini_models_are_refused_before_any_stream() {
  _setup
  local m
  for m in claude-opus-5-5-high claude-sonnet-5-5-medium gpt-oss-120b-medium gemini-pro-orchestrator-neon; do
    rm -f "$TMP/rec/stream.argv"
    _run xhigh FAKE_AGY_MODEL="$m"
    assert_exit 75 "$RC" "$m refused"
    if [ -f "$TMP/rec/stream.argv" ]; then _fail "$m: a stream run was started"; else _ok; fi
  done
}

test_a_failed_model_lookup_skips_agy() {
  _setup
  _run xhigh FAKE_AGY_LOOKUP_FAIL=model
  assert_exit 75 "$RC" "never run unpinned"
  if [ -f "$TMP/rec/stream.argv" ]; then _fail "a stream run was started without a model"; else _ok; fi
}

# --- nothing usable is never a reply ------------------------------------------------
test_an_empty_reply_is_75_and_classifies_as_error() {
  _setup
  _run xhigh FAKE_AGY_MODE=empty
  assert_exit 75 "$RC" "SUCCESS + empty response (antigravity-cli#650)"
  assert_eq ERROR "$(_classify --json-out "$TMP/j")" "an empty reply is not EMPTY → [] → PASS"
  assert_file_contains "denied: command" "$TMP/err"
}

test_a_quota_error_is_visible_to_the_classifier() {
  _setup
  _run xhigh FAKE_AGY_MODE=quota
  assert_exit 75 "$RC" "agy exit 1 becomes 75"
  assert_eq QUOTA "$(_classify --json-out "$TMP/j")" "RESOURCE_EXHAUSTED in result.error reaches stderr"
}

test_usage_at_zero_names_the_window_and_reads_as_quota() {
  _setup
  _run xhigh FAKE_AGY_MODE=error FAKE_AGY_USAGE=0
  assert_file_contains "agy quota exhausted (5h window" "$TMP/err"
  assert_eq QUOTA "$(_classify --json-out "$TMP/j")" "empty bucket → QUOTA"
  _run xhigh FAKE_AGY_MODE=error FAKE_AGY_USAGE=0.5
  assert_eq ERROR "$(_classify --json-out "$TMP/j")" "an auth error with quota left stays ERROR"
}

test_no_result_event_is_75() {
  _setup
  _run xhigh FAKE_AGY_MODE=noresult
  assert_exit 75 "$RC" "a stream that never finished"
}

test_a_hang_is_a_timeout() {
  _setup
  TIMEOUT_S=1 _run xhigh FAKE_AGY_MODE=hang
  assert_exit 124 "$RC" "koji-timeout bounds agy"
}

test_notes_never_mention_quota_without_a_quota() {
  # A note that merely says "quota" would turn a timeout into a 5-hour back-off.
  _setup
  _run max FAKE_AGY_LOOKUP_FAIL=effort
  assert_file_not_contains "quota" "$TMP/err" "clamp/lookup notes are quota-free"
}

# --- tree fingerprint (bypass guard, diagnostic) ------------------------------------
test_a_write_during_the_attempt_is_noted() {
  _setup
  _run xhigh FAKE_AGY_MODE=write
  assert_exit 0 "$RC" "the reply is kept"
  assert_file_contains "koji-note: ⚠ working tree changed during the agy attempt" "$TMP/err"
}

test_a_commit_during_the_attempt_is_noted() {
  # The case the content-only digest missed: edit + commit leaves `git diff HEAD` empty.
  _setup
  local h1; h1=$(git -C "$TMP/repo" rev-parse HEAD)
  _run xhigh FAKE_AGY_MODE=commit
  # The commit must really land: on a host that signs every commit it would
  # fail quietly, and this test would then pass on the staged file alone.
  assert_ne "$h1" "$(git -C "$TMP/repo" rev-parse HEAD)" "the fake reviewer's commit landed"
  assert_file_contains "koji-note: ⚠ working tree changed during the agy attempt" "$TMP/err"
}

test_the_fingerprint_follows_the_project_root_not_the_cwd() {
  _setup
  RC=0
  ( cd / && env FAKE_AGY_MODE=write PATH="$PATH_FAKE" "$AGY_EXEC" 30 xhigh "$TMP/repo" \
      < "$TMP/prompt" > "$TMP/out" 2> "$TMP/err" ) || RC=$?
  assert_file_contains "working tree changed during the agy attempt" "$TMP/err" "measured in PROJECT_ROOT"
}

test_an_untouched_tree_gives_no_note() {
  _setup
  _run xhigh
  assert_file_not_contains "working tree changed" "$TMP/err"
}

# --- front door -------------------------------------------------------------------------
test_harness_markers_stop_it_before_any_lookup() {
  _setup
  local v
  for v in ANTIGRAVITY_CONVERSATION_ID ANTIGRAVITY_TRAJECTORY_ID CODEX_SANDBOX CODEX_THREAD_ID; do
    rm -f "$TMP/rec/"*
    _run xhigh "$v=1"
    assert_exit 78 "$RC" "$v"
    if [ -n "$(ls "$TMP/rec")" ]; then _fail "$v: agy was started"; else _ok; fi
  done
}

test_a_lost_stdin_redirect_fails_instead_of_stalling() {
  _setup
  mkfifo "$TMP/never" 2>/dev/null || true
  exec 9<> "$TMP/never"
  RC=0
  env PATH="$PATH_FAKE" KOJI_BUF_CAP=2 "$AGY_EXEC" 30 xhigh "$TMP/repo" <&9 >/dev/null 2>&1 || RC=$?
  exec 9>&-
  assert_exit 79 "$RC" "an unbounded stdin is a caller error"
}

test_an_unusable_tmpdir_degrades() {
  _setup
  RC=0
  env PATH="$PATH_FAKE" TMPDIR=/nonexistent-koji-agy "$AGY_EXEC" 30 xhigh "$TMP/repo" \
    < "$TMP/prompt" >/dev/null 2>&1 || RC=$?
  assert_exit 125 "$RC" "environment, not caller"
}

test_bad_arguments_are_caller_errors() {
  _setup
  RC=0; env PATH="$PATH_FAKE" "$AGY_EXEC" "" xhigh "$TMP/repo" < "$TMP/prompt" >/dev/null 2>&1 || RC=$?
  assert_exit 79 "$RC" "empty TIMEOUT"
  RC=0; env PATH="$PATH_FAKE" "$AGY_EXEC" 30 medium "$TMP/repo" < "$TMP/prompt" >/dev/null 2>&1 || RC=$?
  assert_exit 79 "$RC" "effort outside max|xhigh|high"
}

# --- fix round: size, lookups, clamp, quota, deny list ---------------------------
test_a_prompt_over_the_cap_goes_by_file() {
  # agy cuts one prompt at ~190 KB. Over koji's cap the whole task goes into a
  # file in the repository's .git directory, and agy gets a short pointer.
  _setup
  python3 -c 'print("HEAD\n" + "x" * 5000)' > "$TMP/prompt"
  _run xhigh KOJI_AGY_MAX_PROMPT=2000 FAKE_AGY_REPLY='[]'
  assert_exit 0 "$RC" "agy answered from the file"
  assert_file_contains "It is in the file" "$TMP/rec/stream.stdin" "the stream prompt points at the file"
  [ "$(wc -c < "$TMP/rec/stream.stdin" | tr -d ' ')" -lt 3000 ] && _ok || _fail "the stream prompt is short"
  cmp -s "$TMP/prompt" "$TMP/rec/task.copy" && _ok || _fail "the task file is exactly the caller's prompt"
  case "$(cat "$TMP/rec/task.path")" in "$TMP/repo/.git/koji-agy."*/task.md) _ok ;; *) _fail "the task file is not in the repository's .git directory: $(cat "$TMP/rec/task.path")" ;; esac
  [ -z "$(find "$TMP/repo/.git" -maxdepth 1 -name 'koji-agy.*' 2>/dev/null)" ] && _ok || _fail "the task dir was not removed"
  assert_file_contains "koji-note: agy reads this" "$TMP/err"
  assert_eq "" "$(git -C "$TMP/repo" status --porcelain)" "git status never sees it"
}

test_no_git_directory_means_no_file_handover() {
  # A linked worktree or a submodule has a .git FILE: agy is skipped, the next
  # provider answers. The plain line carries no number (a size like 164290 must
  # never read as an HTTP 429).
  _setup
  rm -rf "$TMP/plain"; mkdir -p "$TMP/plain"
  python3 -c 'print("HEAD\n" + "x" * 5000)' > "$TMP/prompt"
  RC=0
  env KOJI_AGY_MAX_PROMPT=2000 PATH="$PATH_FAKE" "$AGY_EXEC" 30 xhigh "$TMP/plain" \
    < "$TMP/prompt" > "$TMP/out" 2> "$TMP/err" || RC=$?
  assert_exit 75 "$RC" "no .git directory"
  assert_file_contains "has no .git directory to hand it over in" "$TMP/err"
  if [ -f "$TMP/rec/stream.argv" ]; then _fail "agy was called"; else _ok; fi
  grep -v '^koji-note:' "$TMP/err" | grep -q '[0-9]' && _fail "a plain stderr line carries a number" || _ok
  assert_ne QUOTA "$(_classify --json-out "$TMP/j")" "the skip is never a quota"
}

test_the_size_counts_utf8_bytes_not_json_escapes() {
  # 1,500 CJK chars are 4.5 KB of UTF-8 but 9 KB of JSON \uXXXX escapes.
  _setup
  python3 -c 'print("中" * 1500)' > "$TMP/prompt"
  _run xhigh KOJI_AGY_MAX_PROMPT=7000
  assert_exit 0 "$RC" "measured before JSON escaping"
}

test_an_invalid_cap_falls_back_to_the_default() {
  _setup
  _run xhigh KOJI_AGY_MAX_PROMPT=lots
  assert_exit 0 "$RC" "a small prompt still runs"
  assert_file_contains "KOJI_AGY_MAX_PROMPT='lots' is not a positive integer" "$TMP/err"
}

test_lookups_survive_a_banner_and_pretty_json() {
  _setup
  _run max FAKE_AGY_LOOKUP_BANNER=1
  assert_exit 0 "$RC" "a banner before the lookup JSON"
  assert_contains "--model gemini-4-neon --effort xhigh" "$(cat "$TMP/rec/stream.argv")" "model and clamp still read"
  _setup
  _run max FAKE_AGY_LOOKUP_PRETTY=1
  assert_exit 0 "$RC" "pretty-printed lookup JSON"
  assert_contains "--model gemini-4-neon --effort xhigh" "$(cat "$TMP/rec/stream.argv")" "pretty JSON parsed"
}

test_the_clamp_never_jumps_to_the_most_expensive_tier() {
  _setup
  _run high FAKE_AGY_EFFORTS=xhigh,max
  assert_contains "--effort xhigh" "$(cat "$TMP/rec/stream.argv")" "the lowest level ABOVE high, not max"
}

test_agy_quota_wording_is_normalized() {
  _setup
  _run xhigh FAKE_AGY_MODE=quota
  assert_file_contains "koji-agy-exec: agy quota exhausted:" "$TMP/err"
  assert_eq QUOTA "$(_classify --json-out "$TMP/j")" "exhausted your capacity → QUOTA"
  _run xhigh FAKE_AGY_MODE=quota-stderr
  assert_eq QUOTA "$(_classify --json-out "$TMP/j")" "a rate-limit only on agy's stderr → QUOTA"
  _run xhigh FAKE_AGY_MODE=trace
  assert_file_not_contains "agy quota exhausted" "$TMP/err" "a RateLimiter frame is not a quota"
  assert_eq ERROR "$(_classify --json-out "$TMP/j")" "a RateLimiter stack trace is an error"
}

test_deny_rules_hold_the_table() {
  # The rules agy really receives (the adapter's --settings), checked the way
  # agy 1.5.18 matches them — live-probed; reviewer-backend.md keeps the live
  # table. A chain is checked part by part; a rule matches word by word from
  # the start of a part, never in the middle; a redirect is not part of what a
  # rule sees; and agy drops a backslash, breaks on a quote and drops a `>` in a
  # rule, so no rule may contain one (the first list used `\s`: every regex in
  # it was dead; `.*>.*` matched every command).
  _setup
  _run xhigh
  python3 - "$TMP/rec/stream.argv" <<'PY' && _ok || _fail "deny-rule table (see the output above)"
import json, re, sys
argv = open(sys.argv[1]).read()
deny_json = re.search(r"--settings (\{.*\}) --disable-slash-commands", argv).group(1)
rules = [r[len("command("):-1] for r in json.loads(deny_json)["permissions"]["deny"] if r.startswith("command(")]
mangled = [r for r in rules if any(c in r for c in "\\'\"")]
if mangled:
    print("agy would mangle these rules (backslash or quote):", mangled); sys.exit(1)
# agy reads a `>` in a rule as a redirect and drops it: `.*>.*` and `.*>>.*`
# then match EVERY command (live bisect), so every read is blocked.
block_all = [r for r in rules if ">" in r]
if block_all:
    print("agy reads these as match-everything rules:", block_all); sys.exit(1)
for r in rules:
    if r.startswith("regex:"):
        for tok in r[len("regex:"):].split(" "):
            re.compile(tok)

def parts(cmd):                      # && || ; | outside quotes
    out, cur, q, i = [], "", None, 0
    while i < len(cmd):
        c = cmd[i]
        if q:
            cur += c
            if c == q:
                q = None
        elif c in "'\"":
            q = c; cur += c
        elif cmd.startswith("&&", i) or cmd.startswith("||", i):
            out.append(cur); cur = ""; i += 1
        elif c in ";|" and not (c == "|" and i > 0 and cmd[i - 1] == ">"):
            out.append(cur); cur = ""
        else:
            cur += c
        i += 1
    out.append(cur)
    return [p.strip() for p in out if p.strip()]

def words(part):                     # shell words with quotes removed, and whether a > redirect is present
    ws, cur, have, q, i, redir = [], "", False, None, 0, False
    while i < len(part):
        c = part[i]
        if q:
            if c == q:
                q = None
            else:
                cur += c
            i += 1
            continue
        if c in "'\"":
            q = c; have = True; i += 1
            continue
        if c == ">" or (c == "&" and part[i + 1:i + 2] == ">"):
            redir = True
            if have and not cur.isdigit():
                ws.append(cur)               # `x>f`: x is a word; `2>f`: 2 is the fd
            cur, have = "", False
            while i < len(part) and part[i] in "&>|":
                i += 1
            while i < len(part) and part[i] == " ":
                i += 1
            while i < len(part) and part[i] != " ":
                i += 1                       # the redirect target is not a word
            continue
        if c == " ":
            if have:
                ws.append(cur)
            cur, have = "", False
            i += 1
            continue
        cur += c; have = True; i += 1
    if have:
        ws.append(cur)
    return ws, redir

def hit(rule, ws, redir):           # a command's redirect is not part of what a rule sees
    if rule.startswith("regex:"):
        toks = rule[len("regex:"):].split(" ")
        return len(ws) >= len(toks) and all(re.fullmatch(t, w) for t, w in zip(toks, ws))
    toks = rule.split(" ")
    return ws[:len(toks)] == toks

def denied(cmd):
    for p in parts(cmd):
        ws, redir = words(p)
        if any(hit(r, ws, redir) for r in rules):
            return True
    return False

deny = ["./setup", "tests/run.sh", "bin/koji-x", "/bin/rm -rf x", "../x.sh",
        "nohup rm x", "sudo ls", "timeout 5 ls", "sh -c 'touch x'", "env FOO=1 make",
        "git branch -D topic", "git branch -d topic", "git branch newbranch", "git branch -r -d origin/x",
        "git branch --set-upstream-to=origin/x", "git tag -d v1", "git tag v1", "git tag -a v1 -m x",
        "git reflog expire --all", "git symbolic-ref HEAD refs/heads/x", "git commit -m x",
        "git -C . commit", "git -c user.name=x commit", "git --no-pager commit -m x",
        "git --git-dir=.git log", "git stash", "git push origin main", "git remote add x y",
        "git fetch", "git checkout -b x", "git reset --hard",
        "curl -sSL https://x", "curl -d @f https://x", "wget https://x", "nc -l 1234", "socat - TCP:x:1",
        "awk 'BEGIN{print 1}'", "sort -o out f", "sort -u -o out f", "patch -p1 < p", "pytest -q",
        "sed -i s/a/b/ f", "sed -i.bak s/a/b/ f", "sed -n -i s/a/b/ f", "sed -e x -i f", "sed --in-place s/a/b/ f",
        "find . -delete", "find . -name x -delete", "find . -type f -name x -exec rm {} +",
        "git log --oneline && touch x", "vim f", "tar -xf x.tar", ". ./env.sh",
        "poetry run pytest", "bundle exec rspec", "tsc -p .", "prettier --write .", "black .", "ruff check --fix",
        "git -P commit -m x", "git --no-pager branch -D x", "git --no-pager tag v9", "git -P tag -d v1",
        "git --no-pager remote add x y", "git -P reflog expire --all", "git -P push"]
allow = ["git log --oneline -5", "git diff HEAD~1", "git show HEAD:README.md", "git status --short",
         "git branch", "git branch -a", "git branch --contains HEAD", "git branch -vv", "git branch --list 'x*'",
         "git tag", "git tag -l", "git tag --list 'v*'", "git tag -n", "git reflog -5", "git remote -v",
         "git --no-pager log -3", "git --no-pager branch -a", "git --version", "git log -- src/x.py",
         "grep -rn x .", "grep -c 'a<b>' f", "rg 'Vec<T>' src", "rg 'a => b'", "rg \"foo->bar\"",
         "sed -n 1,5p f", "sed -n -e /x/p f", "sed -E s/a/b/ f", "find . -name '*.md'", "find src -type f -name x",
         "sort f", "sort -u f", "sort -n -k2 f", "cat README.md", "ls -la src/", "head -50 f", "wc -l f",
         "cat a | head -1", "git log --oneline | head -3", "git log 2>/dev/null", "grep -rn x . 2>/dev/null | head",
         "git -P log -3", "git --no-pager branch -a", "git --no-pager tag -l", "git --no-pager remote -v"]
miss = [c for c in deny if not denied(c)]
false = [c for c in allow if denied(c)]
if miss or false:
    print("should deny but allowed:", miss)
    print("should allow but denied:", false)
    sys.exit(1)
PY
}

# --- bypass is an explicit, global opt-in (koji-config agy_bypass yes) ----------
_bypass_on() { mkdir -p "$TMP/state"; printf 'agy_bypass: yes\n' > "$TMP/state/config.yaml"; }
_settings() {   # the one --settings object agy received, as JSON
  python3 -c 'import re,sys; print(re.search(r"--settings (\{.*\}) --disable-slash-commands", open(sys.argv[1]).read()).group(1))' "$TMP/rec/stream.argv"
}

test_bypass_is_off_by_default() {
  _setup
  _run xhigh
  assert_exit 0 "$RC" "a read-only review still answers"
  local argv; argv=$(cat "$TMP/rec/stream.argv")
  assert_not_contains "--dangerously-skip-permissions" "$argv" "no bypass without the opt-in"
  assert_eq 1 "$(grep -o -- '--settings' "$TMP/rec/stream.argv" | wc -l | tr -d ' ')" "exactly one --settings (agy takes one object)"
  python3 -c 'import json,sys
s = json.loads(sys.argv[1])
assert s.get("agentMode") == "", s.get("agentMode")
assert s.get("toolPermission") == "request-review"
assert s.get("allowNonWorkspaceAccess") is False
assert s["permissions"]["deny"]' "$(_settings)" && _ok || _fail "off-mode settings pin agentMode, toolPermission and workspace access"
  assert_file_contains "Shell commands and web tools are not available in this session" "$TMP/rec/stream.stdin"
  assert_file_contains "koji-note: no bypass (koji-config agy_bypass is not yes)" "$TMP/err"
}

test_bypass_on_is_todays_behavior() {
  _setup; _bypass_on
  _run xhigh
  assert_exit 0 "$RC"
  assert_contains "--dangerously-skip-permissions" "$(cat "$TMP/rec/stream.argv")" "the opt-in turns bypass on"
  python3 -c 'import json,sys
s = json.loads(sys.argv[1])
assert "agentMode" not in s and "toolPermission" not in s' "$(_settings)" && _ok || _fail "bypass settings carry the deny list only"
  assert_file_contains "Web search and reading web pages are allowed" "$TMP/rec/stream.stdin"
  assert_file_not_contains "no bypass" "$TMP/err"
}

test_only_an_exact_yes_turns_bypass_on() {
  _setup
  mkdir -p "$TMP/state"; printf 'agy_bypass: true\n' > "$TMP/state/config.yaml"
  _run xhigh
  assert_not_contains "--dangerously-skip-permissions" "$(cat "$TMP/rec/stream.argv")" "'true' is not yes"
}

test_without_bypass_a_write_tool_discards_the_reply() {
  # A future agy that ignores agentMode "", an allow rule from agy's own
  # settings, a subagent: whatever let a non-read tool complete, the reply is
  # not used and the next provider answers.
  _setup
  _run xhigh FAKE_AGY_MODE=toolstep FAKE_AGY_REPLY='[]'
  assert_exit 75 "$RC" "run_command completed without bypass"
  assert_file_contains "agy used run_command although bypass is off" "$TMP/err"
  assert_file_contains "koji-note: ⚠ agy used run_command without bypass" "$TMP/err"
}

test_without_bypass_read_tools_are_fine() {
  _setup
  _run xhigh FAKE_AGY_MODE=readstep FAKE_AGY_REPLY='[]'
  assert_exit 0 "$RC" "read_file and grep_search are read tools"
}

test_without_bypass_a_wrong_permission_mode_discards_the_reply() {
  _setup
  _run xhigh FAKE_AGY_PERMISSION_MODE=always-proceed
  assert_exit 75 "$RC" "agy did not apply request-review"
  assert_file_contains "permission mode always-proceed" "$TMP/err"
}

test_with_bypass_tools_are_allowed() {
  _setup; _bypass_on
  _run xhigh FAKE_AGY_MODE=toolstep FAKE_AGY_REPLY='[]'
  assert_exit 0 "$RC" "under bypass a shell tool is the point"
}

test_without_bypass_needs_tools_is_no_reply() {
  # Live, agy without bypass answered a web-research prompt with a polite "I
  # cannot", which a /triangulate prose site would show as a position. The clause
  # asks for this sentinel instead, and it is no reply.
  _setup
  _run xhigh FAKE_AGY_MODE=needtools
  assert_exit 75 "$RC" "KOJI-NEEDS-TOOLS without bypass"
  assert_file_contains "koji-note: agy needs shell or web tools, which need bypass" "$TMP/err"
  assert_file_contains "reply with exactly KOJI-NEEDS-TOOLS" "$TMP/rec/stream.stdin" "the clause defines it"
  _setup; _bypass_on
  _run xhigh
  assert_file_not_contains "KOJI-NEEDS-TOOLS" "$TMP/rec/stream.stdin" "bypass on: not part of the clause"
}
