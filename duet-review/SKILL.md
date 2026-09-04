---
description: "Two-reviewer adversarial review: Claude + codex in parallel, synthesize, cross-review on disagreement, prompt on auto-apply. Invocation requires the 'duet' keyword."
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Bash
  - Read
  - Edit
  - Write
  - Agent
  - AskUserQuestion
---

# /duet-review

> Follows the [agent-autonomy principle](../references/agent-autonomy.md): agents resolve technical questions together; users see prompts only for policy choices and unresolved deadlocks.

## When to invoke

Use ONLY when the user explicitly types `/duet-review`, says "duet review", "duet-review", "let's duet review this diff", or similar — the `duet` keyword is required. Do NOT invoke on casual "review this" or "code review" phrases — gstack `/review` handles those.

Two-reviewer adversarial code review. **Reviewer A** is Claude (Agent subagent, fresh context — at Claude effort `max` it fans out into five angle reviewers that the main agent consolidates; see Step 2); **Reviewer B** is codex (codex exec, at the effort you picked), or a fresh-context Claude subagent when the duet setup says so. Who reviews, at what effort, on which Claude model is the **duet setup** asked at run start — or handed in by `/duet-impl` for its final review (see **Duet setup** in Arguments). Both run in parallel; results are synthesized into a verdict; reviewer-exclusive findings at severity ≥ medium trigger a cross-review pass with severity-aware AGREE labels; high-consensus mechanical fixes prompt the user with four choices (apply / hold / apply+remember-for-repo / apply+remember-for-session).

## Preamble

```bash
source <(~/.claude/skills/koji/bin/koji-detect)
echo "=== koji duet-review ==="
echo "Project: $PROJECT_NAME"
echo "Session: $SESSION_DIR"
```

## Arguments

**Intent, not flags** — koji skills read natural-language intent; there is no argv to parse. When the user's phrasing signals one of these, set the matching internal variable in Step 1's setup; otherwise the default holds:

- **Base ref for the diff** → `BASE`. By default the base auto-detects (origin/HEAD, then main, then master). If the user names a base ("review against develop", "diff from the release branch", "base is v1.2"), set `BASE` to that ref.
- **Review only staged changes** → `STAGED`. By default the review spans `base..HEAD`. If the user wants the staged diff only ("just the staged changes", "review what's staged", "only the index"), set `STAGED=1` (this ignores `BASE`).
- **Review the working tree (uncommitted)** → `WORKTREE`. By default the review spans `base..HEAD` — committed only. If the user wants the uncommitted working-tree changes ("review my working tree", "review uncommitted changes", "review the working tree since `<sha>`"), set `WORKTREE=1` and optionally `SINCE` to the floor ref (default `HEAD`). This ignores `BASE` and `STAGED`. This is the scope `/duet-impl`'s final review uses — its cumulative work lives uncommitted in the working tree (`HEAD` never moves during the walk).
- **Verdict only, no auto-apply** → `NO_AUTO_APPLY`. By default consensus mechanical fixes prompt the 4-choice apply menu. If the user wants the report without any apply prompt ("no auto-apply", "just the verdict", "report only, don't touch my files", "don't apply anything"), set `NO_AUTO_APPLY=1` — the apply step is skipped and the verdict is emitted as-is. (A required cross-review still runs first; see Step 5.)

**Duet setup** → `TUPLE`. Who fills Reviewer B, at what effort, on which Claude model is decided at the start of this run — never from `.koji.yaml`. Full contract: [`../references/reviewer-backend.md`](../references/reviewer-backend.md). Resolve it **before Step 1's block**: (1) if the invocation phrase carries `duet setup: <tuple>` — `/duet-impl`'s embedded final review — validate it and use it verbatim: no prompt, no save (`EMBEDDED=1`); (2) otherwise baseline (last pick, else defaults) → phrase overlay ("codex at max", "claude reviewer on sonnet", "quick review" → high) → if Reviewer B is still open, ask: *reuse* the last setup, or the dialog. This skill's dialog asks **Reviewer B: codex / Claude** (Reviewer A is always Claude, so `both` and `claude-then-codex` both mean codex here; choosing codex keeps a saved `both` / `claude-then-codex` strategy as-is, choosing Claude sets `claude`), then effort for both families and the Claude reviewer model. `claude` makes Reviewer B a **fresh-context Claude subagent** (never a fork) on the identical reviewer prompt — same-model caveat: two Claude contexts agreeing is two independent readings, not two model families; the disagreement signal is weaker and exact-fingerprint agreement inflates the auto-apply bucket; Step 6 says so in the header.

**Claude reviewer depth: single pass vs angle fan-out** → `REVIEW_MODE`. Reviewer A normally runs as ONE holistic pass (`REVIEW_MODE=single`). It fans out into 5 focused angle reviewers that the main agent consolidates (Step 2b fan-out → Step 2e) when the setup's Claude effort is `max` — or, under `inherit`, when the session is at `/effort max` — or when the invocation phrase explicitly asks for a full/deep review ("full review", "fan out", "all angles", "deep review"). A "quick review" / "lighter pass" / "save tokens" phrase forces `single` even at max. Fan-out roughly 5×'s the Claude-side cost, which is why it rides on the budget question rather than a separate knob. The decision is set at the top of Step 2; single pass is the preserved lightest tier. When `/duet-impl` invokes this skill for its **final review** it passes its tuple: Claude effort `max` there means the 5-angle review, never a single pass.

---

## Step 1 — Scope the diff

Parse arguments. Auto-detect base if not supplied. Generate a diff to a tempfile:

```bash
RUN_DIR=$(mktemp -d -t duet-XXXXXX)
DIFF_FILE="$RUN_DIR/diff.patch"

# Intent-set vars (see "Intent, not flags" in Arguments). Initialized here so
# the reads below run cleanly under set -u even when no intent was signalled.
BASE="${BASE:-}"                     # base ref for the diff (auto-detected below if empty)
STAGED="${STAGED:-}"                 # "1" → review the staged diff only
WORKTREE="${WORKTREE:-}"             # "1" → review uncommitted working-tree changes (ignores BASE/STAGED)
SINCE="${SINCE:-}"                   # floor ref for WORKTREE mode (default HEAD)
NO_AUTO_APPLY="${NO_AUTO_APPLY:-}"   # "1" → skip the apply prompt, emit verdict only (Step 5)
QUOTA_BACKOFF="${QUOTA_BACKOFF:-900}"      # codex quota back-off interval (s), default 15 min
QUOTA_MAX_WAITS="${QUOTA_MAX_WAITS:-20}"   # cap on codex quota back-off retries (~5h)
# Duet setup (see Arguments). The tuple was resolved just before this block —
# embedded phrase → phrase overlay → reuse prompt → dialog → defaults; substitute
# it here. Validate, save as the last pick (not when embedded — the parent saved
# it), record for the run: every later block re-reads $RUN_DIR/duet-setup.
KDS=~/.claude/skills/koji/bin/koji-duet-setup
TUPLE=$("$KDS" validate "<EFFECTIVE tuple>") || exit 1
EMBEDDED="${EMBEDDED:-0}"                        # "1" → invoked by /duet-impl with its tuple
[ "$EMBEDDED" = "1" ] || ~/.claude/skills/koji/bin/koji-config set duet_setup "$TUPLE"
printf '%s\n' "$TUPLE" > "$RUN_DIR/duet-setup"
EFFORT=$("$KDS" field "$TUPLE" 2)          # codex model_reasoning_effort
CLAUDE_EFFORT=$("$KDS" field "$TUPLE" 3)   # koji-reviewer-<effort> agent for EVERY Claude reviewer here (A, angles, B, cross); inherit → general-purpose
CLAUDE_MODEL=$("$KDS" field "$TUPLE" 4)    # Agent `model` param; inherit → omit
CLAUDE_A_UNAVAILABLE="${CLAUDE_A_UNAVAILABLE:-}"  # "1" → Reviewer A (single mode) malformed ×2; Step 6 banner
echo "Duet setup: $("$KDS" summary "$TUPLE")"
CODEX_UNAVAILABLE="${CODEX_UNAVAILABLE:-}"     # "1" → Reviewer B degraded (quota cap, or Claude-B malformed ×2); Step 6 banner
B_RETRIED="${B_RETRIED:-0}"                    # Claude-B malformed-reply retry already used (0/1)

if [ "$WORKTREE" != "1" ] && [ -z "$BASE" ] && [ "$STAGED" != "1" ]; then
  BASE=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|origin/||')
  [ -z "$BASE" ] && BASE=$(git for-each-ref --format='%(refname:short)' refs/heads/main refs/heads/master 2>/dev/null | head -1)
  [ -z "$BASE" ] && BASE="main"
fi

if [ "$WORKTREE" = "1" ]; then
  # Uncommitted working-tree review (used by /duet-impl, whose work is never
  # committed). SINCE floors the diff — default HEAD; /duet-impl passes its
  # session START_SHA (== HEAD, since it never commits).
  SINCE="${SINCE:-HEAD}"
  HEAD_SHA=$(git rev-parse --verify HEAD 2>/dev/null) || { echo "ERROR: no commits to review"; exit 1; }
  # Validate SINCE up front — WORKTREE is the one mode that takes a user-typed
  # ref. A bad ref would otherwise make `git diff` fail, the error get swallowed,
  # and the empty diff read as a false "nothing to review". Surface it loudly.
  git rev-parse --verify "$SINCE^{commit}" >/dev/null 2>&1 || { echo "ERROR: bad SINCE ref: $SINCE"; exit 1; }
  git diff "$SINCE" -- > "$DIFF_FILE"   # '--' disambiguates ref-vs-path; no 2>/dev/null so real failures surface
  BASE="$SINCE"   # label only — feeds the synthesizer's --base
  echo "Scope: working tree since $SINCE (HEAD $HEAD_SHA)"
  # Untracked files are NOT in `git diff` until staged — warn so an unstaged new
  # file isn't silently unreviewed (/duet-impl stages with `git add -A` first).
  if [ -n "$(git ls-files --others --exclude-standard | head -1)" ]; then
    echo "WARN: untracked files exist and are NOT in this review — 'git add -A' to include them."
  fi
elif [ "$STAGED" = "1" ]; then
  git diff --cached > "$DIFF_FILE"
  echo "Scope: staged diff"
else
  HEAD_SHA=$(git rev-parse --verify HEAD 2>/dev/null) || { echo "ERROR: no commits to review"; exit 1; }
  # No 2>/dev/null and an explicit check: a bad or missing base (e.g. the literal
  # `main` fallback on a repo whose trunk is named differently) would otherwise
  # produce an empty diff that reads as "nothing to review" — a silent pass.
  git diff "$BASE...HEAD" > "$DIFF_FILE" || { echo "ERROR: cannot diff $BASE...HEAD — name the base ('review against <ref>')"; exit 1; }
  echo "Scope: $BASE..HEAD ($HEAD_SHA)"
fi

DIFF_LINES=$(wc -l < "$DIFF_FILE" | tr -d ' ')
echo "Diff: $DIFF_LINES lines → $DIFF_FILE"

if [ "$DIFF_LINES" = "0" ]; then
  echo "No diff to review. Exiting."
  exit 0
fi
```

If `DIFF_LINES > 5000`, confirm with the user via `AskUserQuestion` before proceeding (two reviewer passes get expensive — and in fan-out mode the Claude side runs ~5 passes over this diff, so the confirmation matters more).

---

## Step 2 — Launch reviewers in parallel (both backgrounded)

Both reviewers run as **background tasks**. After launching them, briefly tell the user that the reviewers are running and that they can keep working on other things; you'll resume when both background tasks notify completion. Do NOT block on either reviewer mid-flow.

**First, fix the Claude reviewer depth** (see "Claude reviewer depth" in Arguments). Decide from your runtime effort level + the invocation phrase, then record it:

```bash
# REVIEW_MODE: "single" or "fanout". Default follows the setup's Claude effort
# (max → fanout). Set REVIEW_MODE explicitly BEFORE this block only on a phrase
# signal — fanout for full / deep / all-angles / fan-out, single for quick /
# lighter pass / save tokens — or, under `inherit`, when the session is at
# /effort max (fanout). Render-safe: plain string var, no field refs.
CLAUDE_EFFORT=$(~/.claude/skills/koji/bin/koji-duet-setup field "$(head -n1 "$RUN_DIR/duet-setup")" 3) || exit 1
case "$CLAUDE_EFFORT" in max) MODE_DEFAULT=fanout ;; *) MODE_DEFAULT=single ;; esac
REVIEW_MODE="${REVIEW_MODE:-$MODE_DEFAULT}"
# Reviewer B from the run's setup file — authoritative. A lost file is exit 3;
# stop, never default to codex (that would mislabel a claude-B run).
REVIEWER_B=$(~/.claude/skills/koji/bin/koji-duet-backend review-b "$RUN_DIR/duet-setup") || exit 1
# Reviewer A (and its angles) have no sandbox either — snapshot the tree before
# any Claude reviewer is dispatched; 2d compares on collection.
~/.claude/skills/koji/bin/koji-tree-fingerprint > "$RUN_DIR/claude.fp"
echo "Claude reviewer mode: $REVIEW_MODE | Reviewer B backend: $REVIEWER_B"
```

Mode wiring: `single` → run 2b (single pass) + the single-mode half of 2d, and SKIP 2e. `fanout` → run 2b (fan-out) + the fan-out half of 2d, then 2e. Step 2a (Reviewer B) and Steps 3–6 are identical either way. `REVIEWER_B` is orthogonal to `REVIEW_MODE` — every combination is legal; it only selects which 2a leg runs and which 2d/4b/4c collection branch applies.

### 2a. Start Reviewer B in background

**Run the leg matching `REVIEWER_B`.** Both legs end up in the same slot (`$RUN_DIR/codex.json`, written in 2d), so the synthesizer never learns which backend ran — the slot rule in [`../references/reviewer-backend.md`](../references/reviewer-backend.md).

#### 2a — codex leg (`REVIEWER_B=codex`)

```bash
# Codex effort from the run's setup file (fresh shell — never a Step 1 variable).
# TIMEOUT=900 may be set BEFORE this block when the effort is `high`.
EFFORT=$(~/.claude/skills/koji/bin/koji-duet-setup field "$(head -n1 "$RUN_DIR/duet-setup")" 2) || exit 1
TIMEOUT="${TIMEOUT:-1800}"
TO=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || echo "")
PROMPT_FILE="$KOJI_SKILLS/duet-review/references/reviewer-prompt.md"

# Compose prompt inline (the prompt + diff together), write it to a file, and let
# codex read it from stdin (`-`). A large diff can exceed the argv ceiling (macOS
# ARG_MAX ≈ 1 MB shared with env); an E2BIG never starts codex, leaving an empty
# .raw that classifies as ERROR → "[]" → a false PASS. printf is a builtin, so the
# file write has no such limit. A redirect from a regular file EOFs immediately,
# preserving the old `< /dev/null` guarantee that codex never blocks on stdin.
# `-` must be the ONLY positional: a prompt arg plus piped stdin changes framing.
CODEX_PROMPT="$(cat "$PROMPT_FILE")

---

Now review the diff below. Output STRICT JSON only — no markdown fences, no preamble, no commentary. If no findings, output [].

DIFF:
$(cat "$DIFF_FILE")"
PROMPT_TXT="$RUN_DIR/codex.prompt"
printf '%s\n' "$CODEX_PROMPT" > "$PROMPT_TXT"

if [ -n "$TO" ]; then
  "$TO" "$TIMEOUT" codex exec - \
    -C "$PROJECT_ROOT" -s read-only \
    -c "model_reasoning_effort=\"$EFFORT\"" \
    < "$PROMPT_TXT" > "$RUN_DIR/codex.raw" 2> "$RUN_DIR/codex.err"
else
  codex exec - \
    -C "$PROJECT_ROOT" -s read-only \
    -c "model_reasoning_effort=\"$EFFORT\"" \
    < "$PROMPT_TXT" > "$RUN_DIR/codex.raw" 2> "$RUN_DIR/codex.err"
fi
echo $? > "$RUN_DIR/codex.exit"
```

Run this Bash block with **`run_in_background: true`**. The harness returns immediately with a task ID; you (the main agent) will be notified when the command completes. The output file path the harness gives you can also be polled if needed, but the notification is the primary signal.

#### 2a — Claude leg (`REVIEWER_B=claude`)

Record the tree state first — the Claude backend has no `-s read-only` sandbox, only an instruction, so the run detects (not prevents) a reviewer that edits:

```bash
: "${RUN_DIR:?RUN_DIR unset — re-substitute it in this block}"   # an empty prefix would write "/codex.fp"
~/.claude/skills/koji/bin/koji-tree-fingerprint > "$RUN_DIR/codex.fp"   # compared in 2d
```

**Call the `Agent` tool** — a literal tool call; do not narrate "spawning a reviewer" and write the findings yourself. The reviewer runs in a **fresh Agent context, never a fork** — a fork inherits this session's view of the diff, which is exactly the blind spot a second reviewer exists to avoid.

- `subagent_type`: `koji-reviewer-$CLAUDE_EFFORT` (e.g. `koji-reviewer-max`) when `$CLAUDE_EFFORT` is not `inherit`; otherwise `general-purpose`. Unknown type (agents not installed) → print `⚠ koji-reviewer-<x> not installed — run koji setup; falling back to general-purpose (inherit effort)`, `touch "$RUN_DIR/claude-effort-fallback"`, re-dispatch with `general-purpose`.
- `description`: `Duet review: Reviewer B (Claude) pass`
- `model`: **omit this parameter** when `$CLAUDE_MODEL` is `inherit`; otherwise pass its value (`fable` / `opus` / `sonnet`)
- `prompt`: exactly what the codex leg composes — the full `reviewer-prompt.md` text, the closer *"Now review the diff below. Output STRICT JSON only — no markdown fences, no preamble, no commentary. If no findings, output []."*, a `DIFF:` line and the full contents of `$DIFF_FILE` — followed by the **read-only clause** from `../references/reviewer-backend.md`
- `run_in_background`: `true`

Reviewer A (2b) still runs as its own fresh context. Two Claude contexts on disjoint roles is still a duet *structurally*: the orchestrator never judges across the A/B boundary — it collects, writes the slot files, and runs the synthesizer. What changes is the signal strength, and Step 6 says so.

### 2b. Run Claude reviewer (Reviewer A) via Agent tool — also backgrounded

**Run the subsection matching `REVIEW_MODE`.**

#### 2b — single mode (one holistic pass)

Call the `Agent` tool with **`run_in_background: true`**:

- `subagent_type`: `koji-reviewer-$CLAUDE_EFFORT` when `$CLAUDE_EFFORT` is not `inherit`; otherwise `general-purpose` (unknown type → the fallback rule in 2a's Claude leg)
- `model`: **omit** when `$CLAUDE_MODEL` is `inherit`; otherwise its value
- `description`: `Duet review: Claude pass`
- `prompt`: the full reviewer-prompt.md text PLUS the diff, with the closing instruction:
  > *"Output ONLY a JSON array. No markdown fences, no preamble, no closing remarks. If no findings, output `[]`."*
  followed by the **read-only clause** from `../references/reviewer-backend.md` — Reviewer A holds Edit/Write like any subagent
- `run_in_background`: `true`

The Agent tool returns immediately with an agent ID; you'll be notified when the subagent completes.

#### 2b — fan-out mode (5 angle reviewers in parallel)

Read `references/reviewer-prompt.md` and `references/claude-angles.md` (the diff is already at `$DIFF_FILE`). Then make **five consecutive `Agent` tool calls in immediate succession** — one per angle — each with **`run_in_background: true`**, BEFORE the Step 2c message and BEFORE returning control.

For each of the five fixed angles, call the `Agent` tool with:

- `subagent_type`: `koji-reviewer-$CLAUDE_EFFORT` when `$CLAUDE_EFFORT` is not `inherit`; otherwise `general-purpose` (unknown type → the fallback rule in 2a's Claude leg, once; then all five on `general-purpose`)
- `model`: **omit** when `$CLAUDE_MODEL` is `inherit`; otherwise its value
- `description`: the angle number and name, e.g. `Duet review: angle 1 — correctness & safety`
- `prompt`, assembled in this exact order:
  1. the **shared framing** paragraph from `claude-angles.md`,
  2. that angle's **lens block** from `claude-angles.md`,
  3. the **full text of `reviewer-prompt.md`**,
  4. then this closer with the diff inlined — *"Now review the diff below. Output ONLY a JSON array. No markdown fences, no preamble, no closing remarks. If no findings, output `[]`."* — followed by a `DIFF:` line and the full contents of `$DIFF_FILE`,
  5. then the **read-only clause** from `../references/reviewer-backend.md`.
- `run_in_background`: `true`

The five fixed angles (each writes to its numbered file in Step 2d):

1. correctness & safety → `angle-1.json`
2. removed-behavior & dead-code → `angle-2.json`
3. cross-file & caller tracer → `angle-3.json`
4. reuse / simplification / perf → `angle-4.json`
5. altitude / design shape → `angle-5.json`

> **Do NOT return control after launching angle 1** — issue all five `Agent` calls first, then go to Step 2c. If you return early, the remaining angles never start (same discipline as `/triangulate`'s parallel dispatch).

### 2c. Tell the user, then go

After **all** reviewers are launched (Reviewer B + the one Claude reviewer in single mode, or Reviewer B + all five angle agents in fan-out mode), tell the user something like:

> *"duet-review running — Reviewer B (<codex | Claude>) + Claude reviewer(s) launched in background. I'll come back with the verdict when everything completes; in the meantime you can continue with anything else."*

Then **return control**. Do NOT poll, sleep, or proactively check on progress. The harness will re-invoke you with the notification messages.

### 2d. On notification: collect outputs

**Reviewer B — codex leg (`REVIEWER_B=codex`):** when the codex Bash notification arrives, extract its JSON:

```bash
# Classify into a temp file; the slot is published only after the state branch
# AND the schema check pass (tmp → check → rename). The classifier writes `[]`
# on EMPTY, and a parseable-but-malformed array would otherwise sit in
# codex.json where Step 3 reads it as a clean review.
rm -f "$RUN_DIR/codex.json.tmp"
CODEX_STATE=$(~/.claude/skills/koji/bin/koji-codex-classify \
  "$RUN_DIR/codex.raw" "$RUN_DIR/codex.err" "$RUN_DIR/codex.exit" --json-out "$RUN_DIR/codex.json.tmp")
case "$CODEX_STATE" in
  OK)
    if ~/.claude/skills/koji/bin/koji-duet-findings-check "$RUN_DIR/codex.json.tmp"; then
      mv "$RUN_DIR/codex.json.tmp" "$RUN_DIR/codex.json"
    else
      rm -f "$RUN_DIR/codex.json.tmp"; CODEX_STATE=MALFORMED
    fi ;;
  EMPTY) rm -f "$RUN_DIR/codex.json.tmp"; CODEX_STATE=MALFORMED ;;   # exit 0 but no array: not a review — the classifier's synthetic [] never reaches the slot
  *)     rm -f "$RUN_DIR/codex.json.tmp" ;;
esac
echo "codex state: $CODEX_STATE"
```

Branch on `$CODEX_STATE` (per-run loop-state `CODEX_WAITS`, default `0`) — **codex quota is not zero findings**, and neither is an empty reply:

- **`OK`** → `codex.json` written and validated; proceed.
- **`MALFORMED`** (no array, or the array failed `~/.claude/skills/koji/bin/koji-duet-findings-check`) → when `B_RETRIED=0`, set `B_RETRIED=1` and re-dispatch the 2a codex leg once with *"Your last response was not a JSON array of the requested shape — re-output ONLY the array, `[]` if none."* appended to the prompt; a second failure → treat as `ERROR` below.
- **`TIMEOUT` / `ERROR`** → Reviewer B did not review. `WARN: codex $CODEX_STATE — Reviewer B unavailable; this review runs Claude-only (degraded)`; set `CODEX_UNAVAILABLE=1`; write `echo "[]" > "$RUN_DIR/codex.json"` as the degraded-run placeholder (not a finding count — the Step 6 banner declares it); proceed. A codex start failure at the final review must never read as a two-reviewer PASS.
- **`QUOTA`** → do **not** treat as findings. If `CODEX_WAITS < QUOTA_MAX_WAITS`: tell the user *"codex quota/rate-limit — backing off ${QUOTA_BACKOFF}s, retry $((CODEX_WAITS+1))/${QUOTA_MAX_WAITS}"*, dispatch a backgrounded `sleep "$QUOTA_BACKOFF"; <the Step 2a codex exec …>` reading the **same `$PROMPT_TXT` already on disk** — an identical retry, no prompt rebuild (`run_in_background: true`), increment `CODEX_WAITS`, return control; re-classify on notification. If the cap is reached: `echo "WARN: codex unavailable (quota) after $QUOTA_MAX_WAITS back-offs — this review ran Claude-only (degraded, NOT a true duet)"`, set `CODEX_UNAVAILABLE=1`, write `echo "[]" > "$RUN_DIR/codex.json"`, and proceed. The degraded state surfaces in the Step 6 header so it is never a silent pass.

```bash
echo "codex.json:  $(wc -c < "$RUN_DIR/codex.json") bytes"
```

**Reviewer B — Claude leg (`REVIEWER_B=claude`):** when the Reviewer B Agent notification arrives, extract the JSON array from its response, write it to `$RUN_DIR/codex.json.tmp` via the Write tool, run `~/.claude/skills/koji/bin/koji-duet-findings-check "$RUN_DIR/codex.json.tmp"`, and only when it passes `mv` it to `$RUN_DIR/codex.json` — the B slot (a failed check is a malformed reply, below; `rm -f` the temp). **Do not run `koji-codex-classify` on it**: its quota-marker scan over review text would turn a review of rate-limiting code into a phantom `QUOTA`. Then compare the tree fingerprint:

```bash
FP_NOW=$(~/.claude/skills/koji/bin/koji-tree-fingerprint)
[ "$FP_NOW" = "$(cat "$RUN_DIR/codex.fp" 2>/dev/null)" ] \
  || echo "⚠ working tree changed while a read-only reviewer was in flight (reviewer or concurrent work) — review snapshot may be stale"
```

If the response has **no parseable array, or the array fails the check**: when `B_RETRIED=0`, set `B_RETRIED=1` and re-dispatch the same 2a Claude leg once with the reminder *"Your last response was not a JSON array — re-output your findings as ONLY a JSON array, `[]` if none."* On a second failure Reviewer B is **unavailable**: set `CODEX_UNAVAILABLE=1`, write `echo "[]" > "$RUN_DIR/codex.json"` as the degraded-run placeholder — this is *not* a claim of zero findings; the Step 6 banner declares the degradation — and proceed. Never write `[]` for a reply you could not parse without also setting the flag.

**Claude side — single mode:** when the Claude reviewer Agent notification arrives, extract the JSON array from its response, write it to `$RUN_DIR/claude.json.tmp` via the Write tool, run `~/.claude/skills/koji/bin/koji-duet-findings-check` on it, and `mv` it to `$RUN_DIR/claude.json` only when the check passes. If there is no parseable array or the check fails: re-dispatch the same 2b single call once with *"Your last response was not a JSON array of the requested shape — re-output ONLY the array, `[]` if none."* On a second failure Reviewer A is **unavailable**: set `CLAUDE_A_UNAVAILABLE=1` and write `[]` to `claude.json` as the degraded placeholder — not a finding count; the Step 6 banner declares it. **If Reviewer B is also unavailable (`CODEX_UNAVAILABLE=1`), there is no review:** print `ERROR: neither reviewer completed — no verdict` and stop (`exit 1`) before Step 3. Two placeholders must never synthesize into a PASS.

**Claude side — fan-out mode:** each angle agent notifies independently. As each notification arrives, extract its JSON array and write it to its numbered file — `$RUN_DIR/angle-1.json` for angle 1 through `$RUN_DIR/angle-5.json` for angle 5 — via the Write tool. Run `~/.claude/skills/koji/bin/koji-duet-findings-check` on each before writing it into place; if an angle's response has no parseable array or fails the check, write `[]` to its file **and `touch "$RUN_DIR/angle-N.failed"`** (the marker is what distinguishes a dead angle from a clean one across fresh shells), then note it — a dead or garbled angle becomes an empty contributor to the 2e consolidation; it never blocks the review. In 2e, before consolidating, count the markers: if **all five** `angle-*.failed` exist, Reviewer A is unavailable — the single-mode terminal above applies (`CLAUDE_A_UNAVAILABLE=1`, `touch "$RUN_DIR/claude.unavailable"`, `[]` placeholder; no verdict when B is unavailable too). After writing, re-check the all-angles gate:

```bash
ANGLES_DONE=1
for f in angle-1 angle-2 angle-3 angle-4 angle-5; do
  [ -f "$RUN_DIR/$f.json" ] || ANGLES_DONE=0
done
echo "angles present: $ANGLES_DONE"
```

If `ANGLES_DONE=0`, confirm the angle you just collected and return control (the next notification re-invokes you). If `ANGLES_DONE=1`, run **Step 2e** to consolidate the angles into `$RUN_DIR/claude.json`. (If one angle never notifies for an unreasonably long time while all the others are in, treat it as `[]`, write its file, and proceed — do not hang the review.)

**Unavailability must survive fresh shells.** Whenever you set `CODEX_UNAVAILABLE=1`, also `touch "$RUN_DIR/codex.unavailable"`; whenever you set `CLAUDE_A_UNAVAILABLE=1`, also `touch "$RUN_DIR/claude.unavailable"`. The two `[]` placeholders are only ever written alongside their marker file.

**Reviewer A snapshot check.** Reviewer A and its angles hold Edit/Write too. Step 2 fingerprinted the tree into `$RUN_DIR/claude.fp` before dispatch; when the A side is fully collected, compare `~/.claude/skills/koji/bin/koji-tree-fingerprint` against it and print the same `⚠ working tree changed …` line on mismatch (unattributed, as for Reviewer B).

**Proceed to Step 3 only after `$RUN_DIR/codex.json` AND `$RUN_DIR/claude.json` both exist** (in fan-out mode `claude.json` is produced by Step 2e, below) — **and never when both `$RUN_DIR/codex.unavailable` and `$RUN_DIR/claude.unavailable` exist**: then neither reviewer completed, there is no review, print `ERROR: neither reviewer completed — no verdict` and stop (`exit 1`). This check is order-independent: whichever side failed last, the marker files tell the truth. Reviewer B and the Claude side (Reviewer A) run independently; whichever finishes last trips Step 3. If something is still running when you're re-invoked by another notification, just confirm what finished and return control again — the next notification re-invokes you.

> **STOP — the synthesizer is the gate; do not triage by hand.** With both files written, your ONLY next action is **Step 3** (`koji-duet-synthesize`). **You MUST run `koji-duet-synthesize` before you assess, triage, or apply ANY finding.** Reading the raw findings and deciding what to fix yourself — skipping Step 3 — is the single most common failure of this skill. It is not a faster path to the same verdict; it is a *different, worse* one:
>
> - The synthesizer computes `high_consensus` — **which findings both reviewers actually agree on.** Hand-triage fabricates that judgment from one model reading the other's output.
> - The synthesizer arms the cross-review gate (`cross_review_required`). Skip it and a reviewer-exclusive HIGH — exactly the case where one model flags a bug the other cleared — ships on a single model's word, with no second-model check. That cross-review is the whole reason this skill runs two reviewers.
>
> **There is no verdict without the synthesizer.** Do not write a summary, do not open the Edit tool, do not "just apply the obvious ones." Run Step 3.

### 2e. Consolidate angle findings (fan-out mode only)

**Skip this step entirely in single mode** — `claude.json` already exists from Step 2d.

In fan-out mode, once all five `angle-*.json` exist, **you (the main agent) consolidate them into one `$RUN_DIR/claude.json`**. This is judgment work, not a mechanical merge, and you do it yourself — NOT via a subagent — because you hold the diff and the task intent in context. Follow `references/claude-synthesis.md`: pool all angle findings, semantically dedup, treat cross-angle disagreement as signal, verify each survivor against the diff to drop false positives, assign final severity + `suggested_fix`, then write the consolidated JSON array to `$RUN_DIR/claude.json.tmp` via the Write tool (`[]` if nothing survives), run `~/.claude/skills/koji/bin/koji-duet-findings-check "$RUN_DIR/claude.json.tmp"`, and `mv` it to `$RUN_DIR/claude.json` only when the check passes. A failed check is **your own output** — fix the JSON (every entry needs severity, file, integer line, category, description) and re-write it; never proceed on an invalid `claude.json`, and never substitute `[]` for findings you actually have.

Echo a one-line provenance note:

```bash
echo "claude.json: consolidated from 5 angles → $(python3 -c "import json; print(len(json.load(open('$RUN_DIR/claude.json'))))") findings"
```

Then fall through to Step 3 exactly as single mode does — `claude.json` now exists and the Step 3 gate passes.

> **Fan-out priming trap.** You just hand-consolidated five angles in 2e — that was the **last** manual-judgment step in this run. 2e produces `claude.json`; it does **not** decide what to fix. Do not let "I already did the synthesis myself" bleed into hand-triaging the verdict — the Step 2d STOP guard applies here unchanged. Run **Step 3** (`koji-duet-synthesize`) next; it, not you, computes consensus and arms the cross-review.

---

## Step 3 — Synthesize

> You reach this step by running the synthesizer, never around it (see the Step 2d **STOP** guard). With findings collected, `koji-duet-synthesize` is your next action — not triage, not the Edit tool.

```bash
REVIEWER_B=$(~/.claude/skills/koji/bin/koji-duet-backend review-b "$RUN_DIR/duet-setup") || exit 1   # fresh shell: the run file, never a remembered var; exit 3 = run state lost
~/.claude/skills/koji/bin/koji-duet-synthesize \
  --claude "$RUN_DIR/claude.json" \
  --codex  "$RUN_DIR/codex.json" \
  --b-backend "$REVIEWER_B" \
  --base   "$BASE" \
  --head   "$HEAD_SHA" \
  --out    "$RUN_DIR/verdict.json" || SYNTH_RC=$?   # 1/2 = REJECT/CONTESTED — valid verdicts, read from the file below

VERDICT=$(python3 -c "import json; print(json.load(open('$RUN_DIR/verdict.json'))['verdict'])")
CROSS_REQUIRED=$(python3 -c "import json; print(str(json.load(open('$RUN_DIR/verdict.json'))['cross_review_required']).lower())")
echo "First-pass verdict: $VERDICT  (cross_review_required=$CROSS_REQUIRED)"
```

**The synthesizer's stdout also signals this** — when `cross_review_required=true && cross_review_done=false`, the printed verdict carries a `-PRELIMINARY` suffix (e.g. `CONTESTED-PRELIMINARY`, `PASS-WITH-NOTES-PRELIMINARY`). After Step 4 re-runs synthesize with `--cross-review-done`, the suffix drops to the clean `<verdict>`. **If you see `-PRELIMINARY`, your NEXT action is Step 4 — dispatch the cross-review calls. Do NOT skip to Step 5 or Step 6. Step 5 will refuse to run while cross-review is pending.**

---

## Step 4 — Cross-review pass (hard-gated on `cross_review_required`)

The synthesizer sets `cross_review_required = true` whenever ANY reviewer-exclusive finding has severity ≥ medium (lows skip — "not a style committee"). If the flag is `false`, skip this step entirely. If `true`, the orchestrator MUST run this step before Step 5 will accept the verdict.

### 4a. Build the two cross-review payloads

Read `$RUN_DIR/verdict.json` and partition the contested/solo findings by who flagged them:

```bash
python3 - <<'PY' "$RUN_DIR/verdict.json" "$RUN_DIR/codex-cross-targets.json" "$RUN_DIR/claude-cross-targets.json"
import json, sys
src, codex_out, claude_out = sys.argv[1], sys.argv[2], sys.argv[3]
v = json.load(open(src))
# Codex cross-reviews CLAUDE's solo findings; Claude cross-reviews CODEX's.
solo_claude = [f for f in v["high_contested"] + v["medium"] + v["low"]
               if f.get("agreed_by") == ["claude"] and f.get("severity") in ("high","medium")]
solo_codex  = [f for f in v["high_contested"] + v["medium"] + v["low"]
               if f.get("agreed_by") == ["codex"]  and f.get("severity") in ("high","medium")]
json.dump(solo_claude, open(codex_out, "w"))
json.dump(solo_codex,  open(claude_out, "w"))
print(f"Codex will review {len(solo_claude)} Claude findings; "
      f"Claude will review {len(solo_codex)} codex findings")
PY
```

### 4a-bis. Early-exit if both targets are empty

Defensive: if the partition above produced zero targets on BOTH sides, skip Step 4b/4c entirely and flip `cross_review_done` directly (no point dispatching two expensive cross-review subprocesses to assess empty arrays). This case shouldn't normally happen — if `cross_review_required=true`, the synthesizer guarantees ≥ 1 solo high/medium finding — but stale verdict state could trigger it.

```bash
codex_target_count=$(python3 -c "import json; print(len(json.load(open('$RUN_DIR/codex-cross-targets.json'))))")
claude_target_count=$(python3 -c "import json; print(len(json.load(open('$RUN_DIR/claude-cross-targets.json'))))")
if [ "$codex_target_count" = "0" ] && [ "$claude_target_count" = "0" ]; then
  echo "WARN: cross_review_required but both target sets are empty. Marking done and skipping dispatch."
  echo '[]' > "$RUN_DIR/codex.cross.json"
  echo '[]' > "$RUN_DIR/claude.cross.json"
  REVIEWER_B=$(~/.claude/skills/koji/bin/koji-duet-backend review-b "$RUN_DIR/duet-setup") || exit 1   # fresh shell: the run file, never a remembered var
  ~/.claude/skills/koji/bin/koji-duet-synthesize \
    --claude "$RUN_DIR/claude.json" \
    --codex  "$RUN_DIR/codex.json" \
    --b-backend "$REVIEWER_B" \
    --claude-cross "$RUN_DIR/claude.cross.json" \
    --codex-cross  "$RUN_DIR/codex.cross.json" \
    --cross-review-done \
    --base "$BASE" --head "$HEAD_SHA" \
    --out  "$RUN_DIR/verdict.json" || SYNTH_RC=$?   # 1/2 = REJECT/CONTESTED — valid verdicts
  # Skip the rest of Step 4; proceed to Step 5.
fi
```

### 4b. Dispatch both cross-reviews in parallel (background)

Both use **severity-aware AGREE labels** — plain AGREE/DISAGREE loses signal when a reviewer accepts the bug but disputes whether it ships:

- `AGREE-HIGH` — yes, ship-blocking
- `AGREE-MEDIUM` — yes, should-fix but not blocking
- `AGREE-LOW` — yes, nit only
- `DISAGREE` — false positive
- `NEEDS-MORE-CONTEXT` — can't tell from what was shown

Both cross legs keep the A/B boundary: Reviewer B assesses only Reviewer A's solo findings and vice versa, each in its own context; the orchestrator collects and re-synthesizes, never judges. Under `REVIEWER_B=claude` that is still two separate fresh contexts on disjoint target sets — do not "simplify" it into one agent assessing both.

**Reviewer B cross-review — codex leg (`REVIEWER_B=codex`; Bash, background)** — codex reads `$RUN_DIR/codex-cross-targets.json` (Reviewer A's solo findings) and emits a JSON array of `{fingerprint, verdict, rationale}`:

```bash
CROSS_PROMPT="You are Reviewer B. Reviewer A — a separate reviewer — flagged the following findings on this diff that you did not catch in your first-pass review. For each, return your assessment using these severity-aware labels:

  AGREE-HIGH     | yes, ship-blocking
  AGREE-MEDIUM   | yes, should fix but not blocking
  AGREE-LOW      | yes, nit
  DISAGREE       | false positive — explain why
  NEEDS-MORE-CONTEXT | can't tell from what was shown

DIFF:
$(cat "$DIFF_FILE")

REVIEWER A'S FINDINGS TO ASSESS (JSON):
$(cat "$RUN_DIR/codex-cross-targets.json")

Output STRICT JSON only — array of {\"fingerprint\": \"...\", \"verdict\": \"AGREE-HIGH\"|..., \"rationale\": \"one line\"}. No markdown fences. Empty array if nothing to assess."
# Same stdin-file pattern as Step 2a (argv ceiling → false PASS); `-` is the only positional.
CROSS_PROMPT_TXT="$RUN_DIR/codex.cross.prompt"
printf '%s\n' "$CROSS_PROMPT" > "$CROSS_PROMPT_TXT"

if [ -n "$TO" ]; then
  "$TO" "$TIMEOUT" codex exec - \
    -C "$PROJECT_ROOT" -s read-only \
    -c "model_reasoning_effort=\"$EFFORT\"" \
    < "$CROSS_PROMPT_TXT" > "$RUN_DIR/codex.cross.raw" 2> "$RUN_DIR/codex.cross.err"
else
  codex exec - \
    -C "$PROJECT_ROOT" -s read-only \
    -c "model_reasoning_effort=\"$EFFORT\"" \
    < "$CROSS_PROMPT_TXT" > "$RUN_DIR/codex.cross.raw" 2> "$RUN_DIR/codex.cross.err"
fi
echo $? > "$RUN_DIR/codex.cross.exit"
```

Run with **`run_in_background: true`**.

**Reviewer B cross-review — Claude leg (`REVIEWER_B=claude`; Agent, background)** — same target set, same labels, same output file. First `~/.claude/skills/koji/bin/koji-tree-fingerprint > "$RUN_DIR/codex.cross.fp"`. Then **Call the `Agent` tool** — a literal tool call; do not assess Reviewer A's findings yourself. The reviewer runs in a **fresh Agent context, never a fork**: `subagent_type: koji-reviewer-$CLAUDE_EFFORT` (or `general-purpose` under `inherit`; the 2a fallback rule applies), `description: Duet review: Reviewer B (Claude) cross-review`, `model` omitted when `$CLAUDE_MODEL` is `inherit` else its value, `run_in_background: true`, and `prompt` = the exact `$CROSS_PROMPT` text above (with the diff and the targets JSON inlined) followed by the read-only clause from `../references/reviewer-backend.md`. Its array is written to `$RUN_DIR/codex.cross.json` in 4c — the B cross slot.

**Reviewer A cross-review (Agent, background)** — first `~/.claude/skills/koji/bin/koji-tree-fingerprint > "$RUN_DIR/claude.cross.fp"` (the 2d snapshot check covered the first pass only; this leg gets its own). Then call the `Agent` tool with `run_in_background: true`, `subagent_type: koji-reviewer-$CLAUDE_EFFORT` (or `general-purpose` under `inherit`), and `model` omitted when `$CLAUDE_MODEL` is `inherit` else its value. Prompt:

```
You are a code reviewer. Reviewer B — a separate reviewer — flagged the following findings on this diff that you did not catch in your first-pass review. For each, return your assessment using these labels: AGREE-HIGH / AGREE-MEDIUM / AGREE-LOW / DISAGREE / NEEDS-MORE-CONTEXT.

DIFF FILE PATH: <DIFF_FILE>

REVIEWER B'S FINDINGS TO ASSESS (JSON): <contents of $RUN_DIR/claude-cross-targets.json>

Output STRICT JSON ONLY — array of {fingerprint, verdict, rationale}. No markdown fences, no commentary. Empty array if nothing to assess.
```

followed by the **read-only clause** from `../references/reviewer-backend.md` (the A cross reviewer holds Edit/Write too; the `claude.fp` snapshot check in 2d covers it).

### 4c. Collect both responses, re-synthesize

When BOTH notifications arrive, extract JSON arrays, check each with `~/.claude/skills/koji/bin/koji-duet-findings-check --cross`, and write the ones that pass to `$RUN_DIR/codex.cross.json` and `$RUN_DIR/claude.cross.json` (a failed check is the 4d fallback for that side: `[]`). Compare `$RUN_DIR/claude.cross.fp` against a fresh `~/.claude/skills/koji/bin/koji-tree-fingerprint` and print the `⚠ working tree changed …` line on mismatch — the A cross reviewer holds Edit/Write like every other Claude leg. When `REVIEWER_B=codex`, use `koji-codex-classify` for the B cross leg (as in Step 2d): a `QUOTA` state backs off + retries up to `QUOTA_MAX_WAITS` before falling to the 4d safe-degrade — never read a quota reply as an empty cross-review. When `REVIEWER_B=claude`, extract the array from the B cross Agent's response directly — no classifier — and compare `codex.cross.fp` against a fresh `koji-tree-fingerprint` (same `⚠` line as 2d on mismatch). Then re-run the synthesizer with the new inputs:

```bash
REVIEWER_B=$(~/.claude/skills/koji/bin/koji-duet-backend review-b "$RUN_DIR/duet-setup") || exit 1   # fresh shell: the run file, never a remembered var; exit 3 = run state lost
~/.claude/skills/koji/bin/koji-duet-synthesize \
  --claude "$RUN_DIR/claude.json" \
  --codex  "$RUN_DIR/codex.json" \
  --b-backend "$REVIEWER_B" \
  --claude-cross "$RUN_DIR/claude.cross.json" \
  --codex-cross  "$RUN_DIR/codex.cross.json" \
  --cross-review-done \
  --base "$BASE" --head "$HEAD_SHA" \
  --out  "$RUN_DIR/verdict.json" || SYNTH_RC=$?   # 1/2 = REJECT/CONTESTED — valid verdicts

FINAL_VERDICT=$(python3 -c "import json; print(json.load(open('$RUN_DIR/verdict.json'))['verdict'])")
echo "Post-cross-review verdict: $FINAL_VERDICT"
```

**Single pass only.** Do not loop (fatigue-consensus). After this step, `cross_review_done = true` regardless of outcome (REJECT/CONTESTED both stay valid).

### 4d. Failure-mode fallback

If either cross-review times out or returns unparseable JSON, write `[]` for that side and proceed — original solo findings stay solo (safe degradation). A codex quota reply falls here too, but only *after* its back-off retries exhaust (Step 4c) — and it is logged as `codex unavailable (quota)`, distinct from a timeout, so a degraded cross-review is never a silent pass.

---

## Step 5 — Auto-apply prompt (skipped when `NO_AUTO_APPLY` is set)

**Gate:** Step 5 refuses to run if `cross_review_required == true && cross_review_done == false`. Check before proceeding:

```bash
GATE=$(python3 -c "
import json
v = json.load(open('$RUN_DIR/verdict.json'))
if v['cross_review_required'] and not v['cross_review_done']:
    print('BLOCKED')
else:
    print('OK')
")
if [ "$GATE" = "BLOCKED" ]; then
  echo "ERROR: cross_review_required is true but cross_review_done is false."
  echo "       Go back to Step 4 — do NOT print a summary or apply fixes yet."
  exit 1
fi
```

Forces Step 4 to run when required, preventing stale CONTESTED summaries.

**Then, and only after that gate has passed, honor `NO_AUTO_APPLY`.** Placement matters: the skip sits *below* the hard cross-review gate above, so it can never short-circuit a pending/required cross-review — a blocked verdict still `exit 1`s at the gate before we ever reach this check.

```bash
if [ "$NO_AUTO_APPLY" = "1" ]; then
  echo "NO_AUTO_APPLY set — skipping the apply prompt; emitting verdict only."
  # No fixes applied: every high_consensus finding stays for manual review.
  # Leave verdict.json untouched (no auto_applied / user_held mutation) and
  # go straight to Step 6, which prints the verdict as-is.
  SKIP_AUTO_APPLY=1
fi
```

When `SKIP_AUTO_APPLY=1`, skip the rest of Step 5 (5a–5d) entirely and proceed to Step 6. Otherwise run the apply flow below.

Read `$RUN_DIR/verdict.json`. For each finding in `high_consensus` with `suggested_fix.type == "mechanical"` AND `suggested_fix.scope == "single-file"`:

### 5a. Check rule memory

```bash
REPO_RULES="$KOJI_STATE_DIR/repos/$(basename "$PROJECT_ROOT")-$SESSION_HASH/duet-rules.json"
SESSION_RULES="$SESSION_DIR/duet-rules.json"
mkdir -p "$(dirname "$REPO_RULES")" "$SESSION_DIR"

# Rule-memory lookup lives in a helper: the inline version read positional
# params ($1/$2), which the skill renderer silently strips — blanking the
# category/file and mis-gating auto-apply of code edits (safety-sensitive).
```

If `~/.claude/skills/koji/bin/koji-duet-rule-match check "$category" "$REPO_RULES" "$SESSION_RULES"` exits 0 (the category is whitelisted at either scope) → auto-apply silently (use Edit tool with `suggested_fix.details`). Add to `auto_applied` list in the verdict.

### 5b. Otherwise, prompt with 4 choices

Use `AskUserQuestion`:

- **Question**: `"Apply fix for <category> at <file>:<line>?"`
- **Description body**: includes the finding's `description`, both reviewers' agreement, and the `suggested_fix.details`.
- **Options** (single-select, exactly 4):
  1. `Apply` — *"Apply this fix only, this time."*
  2. `Hold` — *"Skip; keep in summary for manual review."*
  3. `Apply + remember for repo` — *"Apply now, and auto-apply this category for this repo from now on."*
  4. `Apply + remember for session` — *"Apply now, and auto-apply this category for the rest of this koji session."*

### 5c. Persist rule choice if user picked 3 or 4

- Choice 3 → `~/.claude/skills/koji/bin/koji-duet-rule-match add "$category" "$REPO_RULES"`
- Choice 4 → `~/.claude/skills/koji/bin/koji-duet-rule-match add "$category" "$SESSION_RULES"`

### 5d. Apply

For choices 1, 3, 4: invoke the Edit tool with `suggested_fix.details` to apply the fix. For choice 2: add to `user_held`. Update `$RUN_DIR/verdict.json` accordingly (move findings between `auto_applied` / `user_held`).

---

## Step 6 — Output

**Gate (same as Step 5):** refuse to print a summary if `cross_review_required && !cross_review_done`. Re-use the gate check from Step 5.

Print a markdown summary to the user:

```
duet-review verdict: <VERDICT>

Setup:     <koji-duet-setup summary of $RUN_DIR/duet-setup> [(claude effort fell back to inherit — agents not installed)]
Reviewers: claude-A (<single pass | fan-out 5 angles>, <claude effort>/<model>) [UNAVAILABLE — malformed] + <codex (<max|xhigh|high>) | claude-B (<claude effort>/<model>)> [UNAVAILABLE — <quota | error | malformed>]
Diff: <N> lines  base=<base>  head=<sha>

Consensus high (X):   <list — auto-applied / held by user / failed apply>
Contested high (Y):   <list>
Medium (Z):           <list>
Low (W):              <list>

Output JSON: <RUN_DIR>/verdict.json
Exit code: <0|1|2>
```

When `CODEX_UNAVAILABLE=1` (codex quota back-off cap reached, codex `TIMEOUT`/`ERROR`, or the Claude-B leg returned no parseable array twice), print `UNAVAILABLE — <quota | error | malformed>` after the Reviewer B entry and add a one-line banner above the verdict — *"⚠ Degraded: Reviewer B (<codex | Claude>) was unavailable; this verdict reflects Reviewer A only, not a two-reviewer duet."* — so the degradation is explicit, never a silent single-reviewer pass. Likewise when `CLAUDE_A_UNAVAILABLE=1` (Reviewer A malformed twice, or every angle failed): `UNAVAILABLE — malformed` after the Reviewer A entry and *"⚠ Degraded: Reviewer A (Claude) was unavailable; this verdict reflects Reviewer B only."* Both unavailable never reaches this step (2d stops with no verdict). The `Setup:` line is `koji-duet-setup summary` of `$RUN_DIR/duet-setup`, with the bracketed fallback note when `$RUN_DIR/claude-effort-fallback` exists.

When `REVIEWER_B=claude`, add one line under the Reviewers line: *"Note: same-model duet (claude + claude) — consensus here means two independent Claude contexts, not two model families; the cross-model disagreement signal is weaker, and exact-fingerprint agreement inflates the auto-apply bucket."* If any `⚠ working tree changed …` fired during 2d/4c, repeat it here as a header note.

Then `exit $EXIT_CODE` where exit code comes from `verdict.json`.

---

## Failure modes

| Symptom | Likely cause | Mitigation |
|---|---|---|
| Codex hangs (no output, no timeout fire) | Stdin not closed, or `--enable web_search_cached` re-introduced | This skill explicitly drops both — verify the bash above wasn't modified. Kill `$CODEX_PID` manually. |
| Codex exits 124 | Hit the timeout. xhigh's 30-min wall isn't enough for very large diffs. | Re-run with smaller scope (name a closer `BASE`), or ask for verdict-only (`NO_AUTO_APPLY`) to at least get the report. |
| Codex quota/rate-limit reply | 5-hour session limit depleted | `koji-codex-classify` returns `QUOTA` (not `[]`) → back off `QUOTA_BACKOFF`s and auto-retry to `QUOTA_MAX_WAITS`; cap reached → Claude-only degraded verdict with an explicit banner (`CODEX_UNAVAILABLE`), never a silent single-reviewer pass. |
| Agent (Claude, Reviewer A) returns prose, or an array that fails `~/.claude/skills/koji/bin/koji-duet-findings-check` | Reviewer prompt drift, or model decided to chat. | Single mode: retry once with the format reminder; second failure → `CLAUDE_A_UNAVAILABLE=1`, `[]` placeholder, degraded banner — and no verdict at all when Reviewer B is unavailable too. Fan-out: that angle becomes `[]`; all five failing is the single-mode terminal. |
| Reviewer B Claude leg returns prose / no array | Same drift, on the B side | Retry once with the format reminder (Step 2d); second failure → `CODEX_UNAVAILABLE=1` + degraded banner. Never a silent `[]` — a B slot placeholder is always announced. Never run `koji-codex-classify` on Claude output. |
| `⚠ working tree changed while a read-only reviewer was in flight` | Reviewer B (Claude leg) edited despite the read-only clause, or the user kept working | Unattributed by design. Inspect `git status`; if the reviewer edited, re-run the review on the intended snapshot. |
| `koji-duet-backend` exits 3: `duet setup file missing/invalid … run state lost` | `$RUN_DIR/duet-setup` is gone or unreadable — the run dir was cleaned, or a block ran with the wrong `RUN_DIR` substituted | Re-substitute `RUN_DIR`. If the file is truly gone, re-run the review — the helper never defaults to codex on a lost file. |
| `⚠ koji-reviewer-<x> not installed` | The reviewer agent definitions were never linked (koji upgraded without re-running `setup`, or the session predates the install) | Reviewers ran on `general-purpose` at inherited effort; the Step 6 `Setup:` line says so. Run `setup`, restart the session. |
| Synthesize crashes | Malformed input (rare; both reviewers were instructed to emit strict JSON) | `koji-duet-synthesize` is defensive: bad input → empty findings → PASS verdict. |
| User chose "remember for repo" but rule doesn't trigger next session | Likely fingerprint mismatch on the OTHER reviewer (consensus didn't form again). Rules need consensus PLUS category match. | This is intentional — rule does not auto-apply on single-reviewer findings. |
| Angle agent (fan-out) returns prose, or never notifies | One of the 5 angle subagents drifted, or its notification was lost | Each angle's collection writes `[]` on an unparseable response; a never-returning angle is treated as `[]` once the others are in (Step 2d). The review completes on the remaining angles — fan-out degrades, never hangs. |
| Step 2e writes invalid or empty `claude.json` | Synthesis emitted non-array JSON | Downstream is forgiving (non-array → empty → PASS), but Step 2e requires a parseable array and `[]` when nothing survives. Sanity-read your own write before Step 3. |

## Related

- Autonomy principle: [../references/agent-autonomy.md](../references/agent-autonomy.md)
- Duet setup and reviewer backend (the tuple; Reviewer B; effort → fan-out; read-only clause; quota rule): [../references/reviewer-backend.md](../references/reviewer-backend.md)
- Verdict JSON spec: [references/verdict-format.md](references/verdict-format.md)
- Reviewer prompt: [references/reviewer-prompt.md](references/reviewer-prompt.md)
- Angle lenses (fan-out mode): [references/claude-angles.md](references/claude-angles.md)
- Angle synthesis spec (fan-out mode): [references/claude-synthesis.md](references/claude-synthesis.md)
- Synthesizer: [koji/bin/koji-duet-synthesize](../bin/koji-duet-synthesize)
- Cleanup: `/wrap` removes `$SESSION_DIR/duet-rules.json` (session-scoped rules expire at wrap)
