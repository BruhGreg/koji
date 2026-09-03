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

Two-reviewer adversarial code review. **Reviewer A** is Claude (Agent subagent, fresh context — at `/effort max` it fans out into multiple angle reviewers that the main agent consolidates; see Step 2); **Reviewer B** is codex (codex exec, `xhigh` effort by default — drop to `high` only via natural-language signal per the Arguments note). Both run in parallel; results are synthesized into a verdict; reviewer-exclusive findings at severity ≥ medium trigger a cross-review pass with severity-aware AGREE labels; high-consensus mechanical fixes prompt the user with four choices (apply / hold / apply+remember-for-repo / apply+remember-for-session).

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

**Codex effort: default xhigh, opt down by saying so.** Codex runs at `xhigh` (~30-min timeout, ~2.5× tokens). Drop to `high` ONLY when the user's invocation phrase signals lighter effort — e.g., "quick review", "lighter pass", "use high effort", "save tokens", "fast check". Don't downgrade for "the diff looks small" or similar heuristics; only on explicit user signal. Claude inherits the parent session's effort level — set `/effort max` once before running if you want max-tier Claude reviewer.

**Claude reviewer depth: single pass (default) vs angle fan-out (max effort)** → `REVIEW_MODE`. Reviewer A normally runs as ONE holistic pass (`REVIEW_MODE=single`). At `/effort max` — or when the invocation phrase explicitly asks for a full/deep review ("full review", "fan out", "all angles", "deep review") — set `REVIEW_MODE=fanout`: Reviewer A instead fans out into 5 focused angle reviewers that the main agent consolidates (Step 2b fan-out → Step 2e). This is Claude-side only and orthogonal to codex's `xhigh`/`high` knob. It roughly 5×'s the Claude-side cost, so it is gated like every other knob here — read from intent, not a flag — and a "quick review" / "lighter pass" / "save tokens" phrase forces `single` even at max effort. The decision is set at the top of Step 2; single pass is the preserved lightest tier. When `/duet-impl` invokes this skill for its **final review**, treat it as a full review: at `/effort max` run `fanout` — that final pass is meant to be the 5-angle review, never a single pass.

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
  git diff "$BASE...HEAD" > "$DIFF_FILE" 2>/dev/null
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
# REVIEW_MODE: "single" (default) or "fanout". Set REVIEW_MODE=fanout BEFORE this
# block when EITHER the session is at /effort max OR the invocation phrase asks
# for a full / deep / all-angles / fan-out review. A "quick" / "lighter pass" /
# "save tokens" phrase forces "single" even at max effort. Render-safe: plain
# string var, no field refs.
REVIEW_MODE="${REVIEW_MODE:-single}"
echo "Claude reviewer mode: $REVIEW_MODE"
```

Mode wiring: `single` → run 2b (single pass) + the single-mode half of 2d, and SKIP 2e. `fanout` → run 2b (fan-out) + the fan-out half of 2d, then 2e. Step 2a (codex) and Steps 3–6 are identical either way.

### 2a. Start codex (Reviewer B) in background

```bash
# Default codex effort: xhigh. Agent sets EFFORT=high TIMEOUT=900 BEFORE this
# block only when the user's invocation phrase signals lighter effort (see
# "Codex effort" note in Arguments above).
EFFORT="${EFFORT:-xhigh}"
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

### 2b. Run Claude reviewer (Reviewer A) via Agent tool — also backgrounded

**Run the subsection matching `REVIEW_MODE`.**

#### 2b — single mode (one holistic pass)

Call the `Agent` tool with **`run_in_background: true`**:

- `subagent_type`: `general-purpose`
- `description`: `Duet review: Claude pass`
- `prompt`: the full reviewer-prompt.md text PLUS the diff, with the closing instruction:
  > *"Output ONLY a JSON array. No markdown fences, no preamble, no closing remarks. If no findings, output `[]`."*
- `run_in_background`: `true`

The Agent tool returns immediately with an agent ID; you'll be notified when the subagent completes.

#### 2b — fan-out mode (5 angle reviewers in parallel)

Read `references/reviewer-prompt.md` and `references/claude-angles.md` (the diff is already at `$DIFF_FILE`). Then make **five consecutive `Agent` tool calls in immediate succession** — one per angle — each with **`run_in_background: true`**, BEFORE the Step 2c message and BEFORE returning control.

For each of the five fixed angles, call the `Agent` tool with:

- `subagent_type`: `general-purpose`
- `description`: the angle number and name, e.g. `Duet review: angle 1 — correctness & safety`
- `prompt`, assembled in this exact order:
  1. the **shared framing** paragraph from `claude-angles.md`,
  2. that angle's **lens block** from `claude-angles.md`,
  3. the **full text of `reviewer-prompt.md`**,
  4. then this closer with the diff inlined — *"Now review the diff below. Output ONLY a JSON array. No markdown fences, no preamble, no closing remarks. If no findings, output `[]`."* — followed by a `DIFF:` line and the full contents of `$DIFF_FILE`.
- `run_in_background`: `true`

The five fixed angles (each writes to its numbered file in Step 2d):

1. correctness & safety → `angle-1.json`
2. removed-behavior & dead-code → `angle-2.json`
3. cross-file & caller tracer → `angle-3.json`
4. reuse / simplification / perf → `angle-4.json`
5. altitude / design shape → `angle-5.json`

> **Do NOT return control after launching angle 1** — issue all five `Agent` calls first, then go to Step 2c. If you return early, the remaining angles never start (same discipline as `/triangulate`'s parallel dispatch).

### 2c. Tell the user, then go

After **all** reviewers are launched (codex + the one Claude reviewer in single mode, or codex + all five angle agents in fan-out mode), tell the user something like:

> *"duet-review running — codex + Claude reviewer(s) launched in background. I'll come back with the verdict when everything completes; in the meantime you can continue with anything else."*

Then **return control**. Do NOT poll, sleep, or proactively check on progress. The harness will re-invoke you with the notification messages.

### 2d. On notification: collect outputs

When the codex Bash notification arrives, extract its JSON:

```bash
CODEX_STATE=$(~/.claude/skills/koji/bin/koji-codex-classify \
  "$RUN_DIR/codex.raw" "$RUN_DIR/codex.err" "$RUN_DIR/codex.exit" --json-out "$RUN_DIR/codex.json")
echo "codex state: $CODEX_STATE"
```

Branch on `$CODEX_STATE` (per-run loop-state `CODEX_WAITS`, default `0`) — **codex quota is not zero findings**:

- **`OK` / `EMPTY`** → `codex.json` written; proceed.
- **`TIMEOUT` / `ERROR`** → `WARN: codex $CODEX_STATE — treating as empty findings`; write `echo "[]" > "$RUN_DIR/codex.json"`; proceed (safe degrade, as before).
- **`QUOTA`** → do **not** treat as findings. If `CODEX_WAITS < QUOTA_MAX_WAITS`: tell the user *"codex quota/rate-limit — backing off ${QUOTA_BACKOFF}s, retry $((CODEX_WAITS+1))/${QUOTA_MAX_WAITS}"*, dispatch a backgrounded `sleep "$QUOTA_BACKOFF"; <the Step 2a codex exec …>` reading the **same `$PROMPT_TXT` already on disk** — an identical retry, no prompt rebuild (`run_in_background: true`), increment `CODEX_WAITS`, return control; re-classify on notification. If the cap is reached: `echo "WARN: codex unavailable (quota) after $QUOTA_MAX_WAITS back-offs — this review ran Claude-only (degraded, NOT a true duet)"`, set `CODEX_UNAVAILABLE=1`, write `echo "[]" > "$RUN_DIR/codex.json"`, and proceed. The degraded state surfaces in the Step 6 header so it is never a silent pass.

```bash
echo "codex.json:  $(wc -c < "$RUN_DIR/codex.json") bytes"
```

**Claude side — single mode:** when the Claude reviewer Agent notification arrives, extract the JSON array from its response and write to `$RUN_DIR/claude.json` via the Write tool. If the response contains no parseable array, write `[]` and note it in the summary.

**Claude side — fan-out mode:** each angle agent notifies independently. As each notification arrives, extract its JSON array and write it to its numbered file — `$RUN_DIR/angle-1.json` for angle 1 through `$RUN_DIR/angle-5.json` for angle 5 — via the Write tool. If an angle's response has no parseable array, write `[]` to its file and note it (a dead or garbled angle becomes an empty contributor; it never blocks the review). After writing, re-check the all-angles gate:

```bash
ANGLES_DONE=1
for f in angle-1 angle-2 angle-3 angle-4 angle-5; do
  [ -f "$RUN_DIR/$f.json" ] || ANGLES_DONE=0
done
echo "angles present: $ANGLES_DONE"
```

If `ANGLES_DONE=0`, confirm the angle you just collected and return control (the next notification re-invokes you). If `ANGLES_DONE=1`, run **Step 2e** to consolidate the angles into `$RUN_DIR/claude.json`. (If one angle never notifies for an unreasonably long time while all the others are in, treat it as `[]`, write its file, and proceed — do not hang the review.)

**Proceed to Step 3 only after `$RUN_DIR/codex.json` AND `$RUN_DIR/claude.json` both exist** (in fan-out mode `claude.json` is produced by Step 2e, below). codex and the Claude side run independently; whichever finishes last trips Step 3. If something is still running when you're re-invoked by another notification, just confirm what finished and return control again — the next notification re-invokes you.

> **STOP — the synthesizer is the gate; do not triage by hand.** With both files written, your ONLY next action is **Step 3** (`koji-duet-synthesize`). **You MUST run `koji-duet-synthesize` before you assess, triage, or apply ANY finding.** Reading the raw findings and deciding what to fix yourself — skipping Step 3 — is the single most common failure of this skill. It is not a faster path to the same verdict; it is a *different, worse* one:
>
> - The synthesizer computes `high_consensus` — **which findings both reviewers actually agree on.** Hand-triage fabricates that judgment from one model reading the other's output.
> - The synthesizer arms the cross-review gate (`cross_review_required`). Skip it and a reviewer-exclusive HIGH — exactly the case where one model flags a bug the other cleared — ships on a single model's word, with no second-model check. That cross-review is the whole reason this skill runs two reviewers.
>
> **There is no verdict without the synthesizer.** Do not write a summary, do not open the Edit tool, do not "just apply the obvious ones." Run Step 3.

### 2e. Consolidate angle findings (fan-out mode only)

**Skip this step entirely in single mode** — `claude.json` already exists from Step 2d.

In fan-out mode, once all five `angle-*.json` exist, **you (the main agent) consolidate them into one `$RUN_DIR/claude.json`**. This is judgment work, not a mechanical merge, and you do it yourself — NOT via a subagent — because you hold the diff and the task intent in context. Follow `references/claude-synthesis.md`: pool all angle findings, semantically dedup, treat cross-angle disagreement as signal, verify each survivor against the diff to drop false positives, assign final severity + `suggested_fix`, then write the consolidated JSON array to `$RUN_DIR/claude.json` via the Write tool (`[]` if nothing survives).

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
~/.claude/skills/koji/bin/koji-duet-synthesize \
  --claude "$RUN_DIR/claude.json" \
  --codex  "$RUN_DIR/codex.json" \
  --base   "$BASE" \
  --head   "$HEAD_SHA" \
  --out    "$RUN_DIR/verdict.json"

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
  ~/.claude/skills/koji/bin/koji-duet-synthesize \
    --claude "$RUN_DIR/claude.json" \
    --codex  "$RUN_DIR/codex.json" \
    --claude-cross "$RUN_DIR/claude.cross.json" \
    --codex-cross  "$RUN_DIR/codex.cross.json" \
    --cross-review-done \
    --base "$BASE" --head "$HEAD_SHA" \
    --out  "$RUN_DIR/verdict.json"
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

**Codex cross-review (Bash, background)** — codex reads `$RUN_DIR/codex-cross-targets.json` (Claude's solo findings) and emits a JSON array of `{fingerprint, verdict, rationale}`:

```bash
CROSS_PROMPT="You are codex. Another reviewer (Claude) flagged the following findings on this diff that you did not catch in your first-pass review. For each, return your assessment using these severity-aware labels:

  AGREE-HIGH     | yes, ship-blocking
  AGREE-MEDIUM   | yes, should fix but not blocking
  AGREE-LOW      | yes, nit
  DISAGREE       | false positive — explain why
  NEEDS-MORE-CONTEXT | can't tell from what was shown

DIFF:
$(cat "$DIFF_FILE")

CLAUDE'S FINDINGS TO ASSESS (JSON):
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

**Claude cross-review (Agent, background)** — call the `Agent` tool with `run_in_background: true`. Prompt:

```
You are a code reviewer. Another reviewer (codex) flagged the following findings on this diff that you did not catch in your first-pass review. For each, return your assessment using these labels: AGREE-HIGH / AGREE-MEDIUM / AGREE-LOW / DISAGREE / NEEDS-MORE-CONTEXT.

DIFF FILE PATH: <DIFF_FILE>

CODEX'S FINDINGS TO ASSESS (JSON): <contents of $RUN_DIR/claude-cross-targets.json>

Output STRICT JSON ONLY — array of {fingerprint, verdict, rationale}. No markdown fences, no commentary. Empty array if nothing to assess.
```

### 4c. Collect both responses, re-synthesize

When BOTH notifications arrive, extract JSON arrays and write to `$RUN_DIR/codex.cross.json` and `$RUN_DIR/claude.cross.json`. For the **codex** cross leg use `koji-codex-classify` (as in Step 2d): a `QUOTA` state backs off + retries up to `QUOTA_MAX_WAITS` before falling to the 4d safe-degrade — never read a quota reply as an empty cross-review. Then re-run the synthesizer with the new inputs:

```bash
~/.claude/skills/koji/bin/koji-duet-synthesize \
  --claude "$RUN_DIR/claude.json" \
  --codex  "$RUN_DIR/codex.json" \
  --claude-cross "$RUN_DIR/claude.cross.json" \
  --codex-cross  "$RUN_DIR/codex.cross.json" \
  --cross-review-done \
  --base "$BASE" --head "$HEAD_SHA" \
  --out  "$RUN_DIR/verdict.json"

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

Reviewers: claude (<single pass | fan-out 5 angles>) + codex (<xhigh|high | UNAVAILABLE — quota>)
Diff: <N> lines  base=<base>  head=<sha>

Consensus high (X):   <list — auto-applied / held by user / failed apply>
Contested high (Y):   <list>
Medium (Z):           <list>
Low (W):              <list>

Output JSON: <RUN_DIR>/verdict.json
Exit code: <0|1|2>
```

When `CODEX_UNAVAILABLE=1` (quota back-off cap reached), print `codex (UNAVAILABLE — quota)` on the Reviewers line and add a one-line banner above the verdict — *"⚠ Degraded: codex was unavailable; this verdict reflects the Claude reviewer only, not a two-reviewer duet."* — so the degradation is explicit, never a silent single-reviewer pass.

Then `exit $EXIT_CODE` where exit code comes from `verdict.json`.

---

## Failure modes

| Symptom | Likely cause | Mitigation |
|---|---|---|
| Codex hangs (no output, no timeout fire) | Stdin not closed, or `--enable web_search_cached` re-introduced | This skill explicitly drops both — verify the bash above wasn't modified. Kill `$CODEX_PID` manually. |
| Codex exits 124 | Hit the timeout. xhigh's 30-min wall isn't enough for very large diffs. | Re-run with smaller scope (name a closer `BASE`), or ask for verdict-only (`NO_AUTO_APPLY`) to at least get the report. |
| Codex quota/rate-limit reply | 5-hour session limit depleted | `koji-codex-classify` returns `QUOTA` (not `[]`) → back off `QUOTA_BACKOFF`s and auto-retry to `QUOTA_MAX_WAITS`; cap reached → Claude-only degraded verdict with an explicit banner (`CODEX_UNAVAILABLE`), never a silent single-reviewer pass. |
| Agent (Claude) returns prose instead of JSON | Reviewer prompt drift, or model decided to chat. | The prompt body explicitly demands strict JSON; the JSON extractor handles single arrays. If the array is missing → treat as `[]`. |
| Synthesize crashes | Malformed input (rare; both reviewers were instructed to emit strict JSON) | `koji-duet-synthesize` is defensive: bad input → empty findings → PASS verdict. |
| User chose "remember for repo" but rule doesn't trigger next session | Likely fingerprint mismatch on the OTHER reviewer (consensus didn't form again). Rules need consensus PLUS category match. | This is intentional — rule does not auto-apply on single-reviewer findings. |
| Angle agent (fan-out) returns prose, or never notifies | One of the 5 angle subagents drifted, or its notification was lost | Each angle's collection writes `[]` on an unparseable response; a never-returning angle is treated as `[]` once the others are in (Step 2d). The review completes on the remaining angles — fan-out degrades, never hangs. |
| Step 2e writes invalid or empty `claude.json` | Synthesis emitted non-array JSON | Downstream is forgiving (non-array → empty → PASS), but Step 2e requires a parseable array and `[]` when nothing survives. Sanity-read your own write before Step 3. |

## Related

- Autonomy principle: [../references/agent-autonomy.md](../references/agent-autonomy.md)
- Verdict JSON spec: [references/verdict-format.md](references/verdict-format.md)
- Reviewer prompt: [references/reviewer-prompt.md](references/reviewer-prompt.md)
- Angle lenses (fan-out mode): [references/claude-angles.md](references/claude-angles.md)
- Angle synthesis spec (fan-out mode): [references/claude-synthesis.md](references/claude-synthesis.md)
- Synthesizer: [koji/bin/koji-duet-synthesize](../bin/koji-duet-synthesize)
- Cleanup: `/wrap` removes `$SESSION_DIR/duet-rules.json` (session-scoped rules expire at wrap)
