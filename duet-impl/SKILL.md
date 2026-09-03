---
description: "Walks a saved plan: 1 foundation gate (codex single) + N post-foundation reviews where the Nth IS the final /duet-review. Invocation requires the 'duet' keyword."
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Agent
  - AskUserQuestion
  - TaskCreate
  - TaskUpdate
  - Skill(duet-review)
---

# /duet-impl

> Follows the [agent-autonomy principle](../references/agent-autonomy.md): agents resolve technical questions together; users see prompts only for policy choices and unresolved deadlocks.

## When to invoke

Use ONLY when the user explicitly types `/duet-impl`, says "duet impl", "duet-impl", "let's duet implement", or similar — the `duet` keyword is required. Do NOT invoke on casual "let's implement" phrases. On review fail: fix-and-retry up to 2 times, then consult codex once, then record a deferral and proceed — the loop never blocks on a modal prompt.

Walks a saved plan from `/duet-plan` (or any structured plan). **Total reviewer passes = 1 foundation gate (codex single) + N post-foundation reviews, where the Nth IS the final `/duet-review`** — never schedule a codex single immediately before the duet-review (it already runs codex + cross-review; a back-to-back single is duplicate work). N is typically 1 (small/mechanical) or 2 (medium, default); rarely 3 (large/dense). See **Review checkpoint strategy** below for placement.

## Preamble

```bash
source <(~/.claude/skills/koji/bin/koji-detect)
echo "=== koji duet-impl ==="
echo "Project: $PROJECT_NAME"
```

## Arguments / plan-path resolution

The plan file path comes from the user's invocation. Examples:

| User said | How to resolve |
|---|---|
| `duet-impl plans/oauth.md` | Treat as direct path |
| `duet-impl the oauth plan` | Glob `$DOCS_PATH/plans/*oauth*.md`; if 1 match, use it; if multiple, AskUserQuestion to pick |
| `let's duet impl what we just planned` | Find most recently modified file in `$DOCS_PATH/plans/` |
| `duet-impl` (no plan) | AskUserQuestion to pick from `$DOCS_PATH/plans/*.md` |

**Intent, not flags** — koji skills read natural-language intent; there is no argv to parse. When the user's phrasing signals one of these, set the matching internal variable before Step 1; otherwise the default holds:

- **Resume from a gate** → `FROM_GATE`. By default the walk starts at the first segment. If the user wants to skip earlier work on a re-run ("resume from the handlers gate", "start at gate X", "skip the foundation, pick up at Y"), set `FROM_GATE` to that gate's name.
- **Skip the final review** → `NO_FINAL_REVIEW`. The run ends with a `/duet-review` by default. If the user only wants a partial implementation with no end-of-run review ("don't run the final review", "skip duet-review", "partial impl only"), set `NO_FINAL_REVIEW=1`.
- **Skip the promise audit** → `NO_PROMISE_AUDIT`. The cumulative promise audit (Step 3a) runs by default. If the user opts out ("skip the promise audit", "no promise check"), set `NO_PROMISE_AUDIT=1`. It is also implied whenever `NO_FINAL_REVIEW=1`.
- **Retry budget per gate** → `RETRIES`. Each gate gets 2 fix-and-retry attempts by default. If the user wants a different budget ("one retry per gate", "fail fast", "3 retries"), set `RETRIES` to that number.
- **Codex quota back-off** → `QUOTA_BACKOFF` (interval seconds, default 900) / `QUOTA_MAX_WAITS` (cap, default 20 ≈ 5h). A codex quota/rate-limit reply is **not** zero findings (Step 2c); the run backs off `QUOTA_BACKOFF`s and retries up to `QUOTA_MAX_WAITS` times — auto-resuming when the 5-hour window restores — then treats codex as unavailable (records a deferral and proceeds). Tune via intent ("retry every 10 minutes", "give up after an hour", "wait all night").

**Stuck gates never block (default, no toggle).** When a gate can't clear after `RETRIES` + the consult round, the unresolved HIGH is recorded as a **deferral** — appended to `$RUN_DIR/deferred-findings.md` and the Step 6 report — and the walk proceeds. The deferred code stays in the cumulative diff, so the end-of-run `/duet-review` re-examines it. This is the only posture: `/duet-impl` runs are unattended-safe by design and never freeze on a modal prompt. Nothing is silently dropped — every deferral is a documented decision surfaced at end-of-run.

**Codex effort: default xhigh, opt down by saying so.** Codex runs at `xhigh` (~30-min timeout, ~2.5× tokens) for each gate review. Drop to `high` ONLY when the user's invocation phrase signals lighter effort — e.g., "quick gates", "lighter review", "use high effort", "save tokens". Don't downgrade for "the gate diff looks small"; only on explicit user signal. Claude inherits the parent session's effort level.

## Review checkpoint strategy

Two kinds of review checkpoint, separately budgeted:

1. **Foundation gate** — one codex single-review after foundation steps land (scaffolding with no standalone behavior: new types, trait-shape changes, mechanical stubs that just make the workspace compile). Validates the base before downstream depends on it. Skip only when the plan has no distinct foundation phase.
2. **Post-foundation reviews** — `N` reviews distributed across the remaining work at fractional positions `1/N, 2/N, …, N/N`. **The `N/N` position IS the final `/duet-review`** (two reviewers + cross-review); the intermediate `1/N … (N-1)/N` positions are codex single-reviews. So `N` includes the duet-review in its count, NOT in addition to it.

**Total reviewer passes = 1 (foundation gate) + N (post-foundation reviews, the last of which is the duet-review).**

Pick `N` by weighting the *post-foundation* work — LoC density, risk inflections, and how much real reasoning each step requires. Mechanical pattern-application counts for less; cross-layer or pattern-establishing steps count for more. Default by size:

| Post-foundation work | `N` | Positions | Total passes (incl. foundation) |
|---|---|---|---|
| Small / mostly mechanical (<5 PRs) | 1 | duet-review at end only | 2 |
| Medium (default) | 2 | codex single at 1/2, duet-review at 2/2 | 3 |
| Large or dense (>10 PRs, multiple risk inflections) | 3 | codex singles at 1/3 + 2/3, duet-review at 3/3 | 4 |

**Position is a judgment call, not strict math.** Slide each fractional checkpoint a step or two to land it on a natural seam — right after a pattern is established, right before a cross-layer transition, right before a risk inflection. Mechanical/mindless steps lower the weight; heavy-reasoning steps raise it. For a 12-step plan with `s1+s2` foundation and 10 steps remaining at `N=2`, the mid-term codex single would land at ~`s2 + 5 = s7`, but it's fine to slide to `s6` or `s8` if the natural seam is there.

**Anti-patterns:**

1. **One gate per step.** Codex single-review at every step is expensive, fatigues the reviewer, and produces noise that obscures high-signal findings. Reserve exhaustive coverage for the final `/duet-review`.
2. **A codex single-review immediately before the final `/duet-review`.** The duet-review already runs codex + cross-review; a back-to-back single-review is duplicate work. The final reviewer pass IS the duet-review — there is no separate "Gate N codex single + then duet-review" pattern. Schedule `N` total post-foundation reviews, not `N+1`.
3. **Treating "gate count" as a flat number.** Don't think "3 gates means 3 codex singles plus a duet-review at the end." Think "1 foundation gate + N post-foundation reviews, the last of which is the duet-review." Total reviewer passes is the explicit sum.

For plans with `<!-- gate: NAME -->` markers, honor them as explicit boundaries. For plans without markers (the common case), derive boundaries from structure: numbered `### Step N` headings, sectional H2/H3 breaks, or the agent's reading of natural cohesion.

## Step 1 — Identify checkpoints from the plan

The agent reads the plan and decides checkpoint placement per the **Review checkpoint strategy** above. This is a judgment call from plan structure — no parser tool.

```bash
PLAN_FILE="<resolved-path>"
[ -f "$PLAN_FILE" ] || { echo "ERROR: plan not found: $PLAN_FILE"; exit 1; }

# Capture starting SHA (for diff computation later)
START_SHA=$(git rev-parse --verify HEAD 2>/dev/null) || { echo "ERROR: no commits yet"; exit 1; }
RUN_DIR=$(mktemp -d -t duet-impl-XXXXXX)

# Effort: see "Codex effort" in Flags above for the opt-down rule.
EFFORT="${EFFORT:-xhigh}"
TIMEOUT="${TIMEOUT:-1800}"
RETRIES="${RETRIES:-2}"
# Intent-set vars (see "Intent, not flags" above). Initialized here so the
# reads below run cleanly under set -u even when no intent was signalled.
FROM_GATE="${FROM_GATE:-}"           # gate name to resume from (Step 2a)
FROM_GATE_REACHED="${FROM_GATE_REACHED:-}"  # loop state for the FROM_GATE resume skip (Step 2a)
NO_FINAL_REVIEW="${NO_FINAL_REVIEW:-}"      # skip end-of-run /duet-review (Step 3b)
NO_PROMISE_AUDIT="${NO_PROMISE_AUDIT:-}"    # skip the promise audit (Step 3a)
QUOTA_BACKOFF="${QUOTA_BACKOFF:-900}"        # codex quota back-off interval (s), default 15 min
QUOTA_MAX_WAITS="${QUOTA_MAX_WAITS:-20}"     # cap on quota back-off retries per gate (~5h)
echo "Start SHA: $START_SHA | Run dir: $RUN_DIR | Effort: $EFFORT | Retries/gate: $RETRIES"
```

Then **read the plan** (via the `Read` tool), identify the natural checkpoint boundaries per the strategy above, and announce the proposed plan in one sentence before Step 2 begins. State explicitly: foundation gate (yes/no), `N`, the positions, and the total reviewer-pass count. Example:

> "Plan has 2 foundation steps + 11 post-foundation steps. Proposing **foundation gate (codex single after Step 2)** + **`N=2` post-foundation reviews**: mid-term codex single after Step 7, final `/duet-review` after Step 11. **Total: 3 reviewer passes** (1 foundation + 2 post-foundation, the second of which IS the duet-review)."

The user can redirect before any work starts. Each checkpoint becomes a "segment" used by Step 2 — checkpoint name + the plan text governing that segment's scope. Note that the FINAL segment's review is the `/duet-review` itself (Step 3 below), so Step 2 walks only the foundation gate + the `1/N … (N-1)/N` codex singles — Step 2 does NOT execute a codex single at position `N/N`.

**Create the progress task list.** With the checkpoints fixed, call `TaskCreate` to lay out the walk as a task list — one task per segment in plan order, named for its checkpoint (e.g. `Foundation: types + scaffolding`, `Segment 2: handlers`), plus a final task for the `/duet-review` pass. This is required, not optional: it is the live checklist the user watches while the implementation runs. Step 2 keeps it current.

## Step 2 — Walk codex-reviewed checkpoints

**Keep the machine awake for the walk** (once, before the per-checkpoint loop): the gate reviews dispatch as background tasks across many turns, so the user can step away. Refcounted + self-cleaning; never touches a caffeinate the user started. Torn down in Step 6. No `/wrap` dependency.

```bash
~/.claude/skills/koji/bin/koji-keepawake start || true
```

For each checkpoint that has a codex single-review attached (foundation gate + the `1/N … (N-1)/N` post-foundation positions), in order:

> NOTE: the `N/N` position is the final `/duet-review`, handled by Step 3 — **do not** schedule a codex single-review at end-of-plan. Step 2 stops one position short of the end.

**Keep the task list current.** As you walk each checkpoint: `TaskUpdate` its task to `in_progress` when its segment work begins (2b), and to `completed` when its gate review passes (2d PASS). Mark the final `/duet-review` task `completed` once Step 3's verdict is in. The user is watching this checklist — it must track the real state of the walk.

### 2a. Skip earlier gates when resuming (`FROM_GATE`)

```bash
if [ -n "$FROM_GATE" ] && [ "$gate_name" != "$FROM_GATE" ] && [ "$FROM_GATE_REACHED" != "1" ]; then
  echo "Skipping $gate_name (resuming from gate: $FROM_GATE)"
  continue
fi
FROM_GATE_REACHED=1
```

### 2b. Implement the segment

The agent reads the gate's governing plan text and executes the described work using Edit/Write/Bash tools. This is the part where /duet-impl effectively does the coding — the plan tells *what*, the agent figures out *how* (file paths, edits, test runs).

Concretely the agent should:
1. Re-read the plan section(s) for this gate. Identify concrete file edits, new files, dependency changes, test additions.
2. Make the changes via Edit/Write tools.
3. If the plan specifies running tests/commands, run them via Bash.
4. Capture a snapshot SHA for diff computation:
   ```bash
   SEGMENT_START_SHA="${PREV_GATE_SHA:-$START_SHA}"
   # ... implementer does work ...
   # No automatic commit per gate; the diff is computed against worktree, not commits
   ```

Recommendation: stage changes (`git add -A`) after segment work so diff computation in 2c is deterministic.

### 2c. Codex single-review at this gate (background)

```bash
SEGMENT_DIFF_FILE="$RUN_DIR/diff-${gate_name}.patch"
git diff "$SEGMENT_START_SHA" -- > "$SEGMENT_DIFF_FILE"   # working-tree diff since segment start

GATE_PROMPT_TEMPLATE="$KOJI_SKILLS/duet-impl/references/gate-review-prompt.md"
PHASE_TEXT="<plan text for this gate — agent extracts from the plan file>"

# The agent reads the "## Reviewer prompt" template from $GATE_PROMPT_TEMPLATE and
# fills its placeholders to construct $CODEX_PROMPT inline: {gate_name} → $gate_name,
# {phase_text} → $PHASE_TEXT, {diff} → the contents of $SEGMENT_DIFF_FILE. Then:
TO=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || echo "")
RAW="$RUN_DIR/codex-${gate_name}-attempt-${attempt}.raw"

# Prompt → file → codex stdin (`-`). A gate diff can exceed the argv ceiling
# (macOS ARG_MAX ≈ 1 MB shared with env); an E2BIG never starts codex, leaving an
# empty .raw that classifies ERROR → "[]" → a false PASS at the gate. printf is a
# builtin (no argv). A regular-file redirect EOFs immediately, so codex never
# blocks on stdin (the old `< /dev/null` property). `-` must be the ONLY positional.
PROMPT_TXT="$RAW.prompt"
printf '%s\n' "$CODEX_PROMPT" > "$PROMPT_TXT"

if [ -n "$TO" ]; then
  "$TO" "$TIMEOUT" codex exec - \
    -C "$PROJECT_ROOT" -s read-only \
    -c "model_reasoning_effort=\"$EFFORT\"" \
    < "$PROMPT_TXT" > "$RAW" 2> "$RAW.err"
else
  codex exec - -C "$PROJECT_ROOT" -s read-only \
    -c "model_reasoning_effort=\"$EFFORT\"" < "$PROMPT_TXT" > "$RAW" 2> "$RAW.err"
fi
echo $? > "$RAW.exit"
```

Run this Bash block with **`run_in_background: true`**. Tell the user: *"Gate '$gate_name' attempt $((attempt+1)): codex reviewing in the background."* Then return control. When the notification arrives, **classify** the result (per-gate loop-state `QUOTA_WAITS`, initialized to `0` alongside `attempt=0` at the top of each gate; orthogonal to `RETRIES`):

```bash
FINDINGS="$RUN_DIR/findings-${gate_name}-attempt-${attempt}.json"
STATE=$(~/.claude/skills/koji/bin/koji-codex-classify "$RAW" "$RAW.err" "$RAW.exit" --json-out "$FINDINGS")
echo "Gate $gate_name attempt $((attempt+1)): codex state = $STATE"
```

Branch on `$STATE`:

- **`OK`** → findings written; proceed to 2d.
- **`EMPTY` / `TIMEOUT` / `ERROR`** → **a quota reply is not an empty findings array**, but these three are treated as empty: log `WARN: codex $STATE — treating as empty findings this attempt` and run `echo "[]" > "$FINDINGS"` (the classifier writes `[]` for `EMPTY` but not for `TIMEOUT`/`ERROR`, so guarantee the file exists before 2d's `json.load`), then proceed to 2d. *(Scope: timeout/error keep the prior treat-as-empty semantics; only `QUOTA` gets the back-off path.)*
- **`QUOTA`** → do **not** write a PASS. If `QUOTA_WAITS < QUOTA_MAX_WAITS`: tell the user *"Gate '$gate_name': codex quota/rate-limit — backing off ${QUOTA_BACKOFF}s, retry $((QUOTA_WAITS+1))/${QUOTA_MAX_WAITS}"*, then dispatch a backgrounded block that sleeps and re-runs the **same** codex invocation from 2c, reading the `$PROMPT_TXT` already on disk — an identical retry, no prompt rebuild (`sleep "$QUOTA_BACKOFF"; <codex exec - …> < "$PROMPT_TXT" > "$RAW" 2> "$RAW.err"; echo $? > "$RAW.exit"`) with `run_in_background: true`, increment `QUOTA_WAITS`, and return control; re-classify on the next notification. If `QUOTA_WAITS` has reached `QUOTA_MAX_WAITS`, codex is **unavailable** → record a deferral (reason *"codex unavailable — quota, $QUOTA_MAX_WAITS back-offs"*) and proceed to the next gate.

### 2d. Decide PASS / FIX / DEFER

```bash
FINDINGS="$RUN_DIR/findings-${gate_name}-attempt-${attempt}.json"
HIGH_COUNT=$(python3 -c "import json; print(sum(1 for f in json.load(open('$FINDINGS')) if f.get('severity')=='high'))")

if [ "$HIGH_COUNT" = "0" ]; then
  echo "Gate $gate_name: PASS"
  PREV_GATE_SHA=$(git rev-parse HEAD)
  continue   # to next segment
fi

# High findings present
if [ "$attempt" -lt "$RETRIES" ]; then
  echo "Gate $gate_name: $HIGH_COUNT high finding(s), attempting fix (retry $((attempt+1))/$RETRIES)"
  # Apply the fixes (see prose below), then:
  attempt=$((attempt+1))
  # Loop back to 2c
else
  echo "Gate $gate_name: retry budget exhausted, consulting codex once"
  # Consult round: ask codex to re-examine its findings given that 2 fixes didn't satisfy.
  # If consult resolves it (codex agrees fixes are now fine), PASS.
  # Otherwise the loop never blocks: it is a recorded deferral, not a blocking prompt.
  # Record it and proceed — the only posture, unattended-safe by design.
  echo "Gate $gate_name: recording $HIGH_COUNT unresolved high finding(s) as deferred, proceeding"
  # Append the unresolved HIGH(s) to $RUN_DIR/deferred-findings.md (template below).
  PREV_GATE_SHA=$(git rev-parse HEAD)   # deferred code stays in the cumulative diff
  continue   # to next segment
fi
```

The **codex-unavailable** terminal from Step 2c (`QUOTA_WAITS` cap reached) is handled the same way: record a deferral with reason *"codex unavailable — quota"* and proceed to the next gate.

**Deferral artifact (`$RUN_DIR/deferred-findings.md`).** Written with the Write tool — create-with-header on the first deferral of the run, append a `## Gate:` block on each subsequent one (text formatting, so prose-templated, not a helper). Record the finding + *why 2 rounds couldn't resolve it* + the gate:

```markdown
# Deferred findings — /duet-impl run
Plan: <PLAN_FILE>   Run dir: <RUN_DIR>   Start SHA: <START_SHA>
Recorded because the gate could not resolve within RETRIES + consult, or codex was
unavailable. The loop never blocks — it defers and proceeds. Code remains in the
cumulative diff — the end-of-run /duet-review re-examines it.

---
## Gate: <gate_name>
- Why deferred: <RETRIES + consult exhausted | codex unavailable — quota, N back-offs>
- Findings (<HIGH_COUNT>):
  - `<file>:<line>` [<category>] <description>
    fix: <suggested_fix.details>
```

When retrying (the `if` branch above), apply each high finding before looping back to 2c: read `$FINDINGS` and, for every finding with `severity == high`, invoke the Edit tool with that finding's `suggested_fix.details` to apply the fix — same mechanism as `/duet-review` Step 5d. This is a tool action, not a shell call; there is no batch helper.

Per the autonomy principle, the consult-codex round is the "agents try together" step *before* recording a deferral. The consult prompt is:

> *"You flagged these high findings on gate '$gate_name'. The implementer made 2 fix attempts that you still flagged. Either: (a) reconfirm with specific code-level guidance the implementer can apply, or (b) acknowledge if your earlier findings may have been mistaken given the work as-is."*

## Step 3 — Final review phase (promise audit + /duet-review)

After all segments are processed (or a `FROM_GATE` resume reaches the end), the final review phase has two sub-steps:

- **3a Promise audit** — extracts every explicit contract promise from the locked plan and verifies each one in the cumulative diff. Skipped when `NO_PROMISE_AUDIT` or `NO_FINAL_REVIEW` is set.
- **3b Final `/duet-review`** — two-reviewer adversarial review on the cumulative diff. Skipped when `NO_FINAL_REVIEW` is set.

The two sub-steps share `$RUN_DIR/final-diff.patch` (cumulative `$START_SHA..HEAD` diff). Whichever runs first writes it; the other reuses. Alongside the patch, the first writer also captures `$RUN_DIR/final-diff.numstat` — the `koji-diff-numstat "$START_SHA"` add/delete counts at the **final-review snapshot**, BEFORE Step 4 reconciliation and Step 5 convention-doc edits land. Step 6's code-delta ratio reads this snapshot so it measures the reviewed code, not the later bookkeeping edits.

**Stage the cumulative work first — once, here.** Before any diff is computed, stage everything so a single, complete change-set feeds the promise audit, the code-delta numstat, AND the final `/duet-review`. Untracked new files are invisible to `git diff` until staged, and the review must see them:

```bash
git add -A   # one staging point; /wrap commits the staged tree later
```

This makes `final-diff.patch` (3a) and the `/duet-review` WORKTREE scope (3b) describe the **same** set — new files included — so the Step 6 ratio matches exactly what was reviewed.

### Step 3a — Promise audit

```bash
if [ "$NO_PROMISE_AUDIT" = "1" ] || [ "$NO_FINAL_REVIEW" = "1" ]; then
  echo "Skipping promise audit"
  PROMISE_AUDIT_RAN=0
else
  PROMISE_AUDIT_RAN=1
  # Compute cumulative diff once for both 3a and 3b.
  git diff "$START_SHA" -- > "$RUN_DIR/final-diff.patch"
  # Snapshot the code-delta counts at the final-review point, BEFORE Step 4/5
  # bookkeeping edits, so Step 6's ratio measures the reviewed code. Capture the
  # helper's exit so a failure is observable (don't silently drop the snapshot).
  ~/.claude/skills/koji/bin/koji-diff-numstat "$START_SHA" > "$RUN_DIR/final-diff.numstat" \
    || echo "WARN: final-review numstat snapshot failed; Step 6 will fall back to a live diff" >&2
  echo "Cumulative diff at: $RUN_DIR/final-diff.patch"
fi
```

If the audit is enabled, dispatch the auditor as a backgrounded `Agent` call. The auditor is a Claude subagent (fresh context — it does not inherit the implementer's view of the work, which is the point: contract verification must be done by someone who reads only the plan and the diff, not someone who knows what the implementer meant).

Call the `Agent` tool with `run_in_background: true`:

- `subagent_type`: `general-purpose`
- `description`: `Duet-impl promise audit`
- `prompt`: the "Auditor prompt" template from [references/promise-audit-prompt.md](references/promise-audit-prompt.md), with `{plan_text}` replaced by the locked plan file's full contents and `{diff_text}` replaced by `$RUN_DIR/final-diff.patch` contents.
- `run_in_background`: `true`

Tell the user: *"Promise audit: auditor reading plan + cumulative diff in the background."* Then return control. When the notification arrives, extract the JSON array from the agent's response and write to `$RUN_DIR/promise-audit.json` via the Write tool. If the response contains no parseable array (timeout, prose-only response, malformed JSON), write `[]` and log: `WARN: promise audit returned no parseable JSON — treating as zero promises found. Run continues.` The audit is a guardrail, not a gate — a flaky audit must not block 3b.

Then count gaps for the Step 6 report:

```bash
if [ "$PROMISE_AUDIT_RAN" = "1" ]; then
  PROMISE_AUDIT_TOTAL=$(python3 -c "import json; print(len(json.load(open('$RUN_DIR/promise-audit.json'))))" 2>/dev/null || echo 0)
  PROMISE_AUDIT_GAPS=$(python3 -c "import json; print(sum(1 for p in json.load(open('$RUN_DIR/promise-audit.json')) if p.get('evidence') == 'GAP'))" 2>/dev/null || echo 0)
  echo "Promise audit: $PROMISE_AUDIT_TOTAL promises checked, $PROMISE_AUDIT_GAPS gaps found"
fi
```

### Step 3b — Final /duet-review

```bash
if [ "$NO_FINAL_REVIEW" = "1" ]; then
  echo "Skipping final /duet-review (NO_FINAL_REVIEW set)"
else
  # Reuse cumulative diff from 3a if it ran; compute now if not.
  [ -f "$RUN_DIR/final-diff.patch" ] || git diff "$START_SHA" -- > "$RUN_DIR/final-diff.patch"
  # Snapshot code-delta counts at the final-review point if 3a didn't already
  # (same rationale: measure reviewed code, before Step 4/5 bookkeeping edits).
  [ -f "$RUN_DIR/final-diff.numstat" ] \
    || ~/.claude/skills/koji/bin/koji-diff-numstat "$START_SHA" > "$RUN_DIR/final-diff.numstat" \
    || echo "WARN: final-review numstat snapshot failed; Step 6 will fall back to a live diff" >&2
  echo "Running /duet-review on the cumulative diff since $START_SHA..."
  echo "Full diff at: $RUN_DIR/final-diff.patch"
fi
```

**Invoke the real `/duet-review` skill — do not hand-roll it.** Use the **Skill tool** (`skill: duet-review`) so its `SKILL.md` actually loads into context; the loaded skill owns the reviewer machinery (codex + the Claude angle fan-out, synthesis, cross-review). Do **NOT** rebuild the review from memory with `Agent`/`Bash` — that path silently drops the Claude-side fan-out (Reviewer A runs 1 agent instead of 5). `Skill(duet-review)` is pre-approved in this skill's `allowed-tools`, so the invocation won't stall on a mid-run permission prompt.

Hand it the right **scope** and **depth** in the invocation phrase:

- **Scope → the working tree.** Phrase it as *"review the working tree since `<START_SHA>`"* so `/duet-review` runs in `WORKTREE` mode (`SINCE=$START_SHA`), NOT its default `BASE...HEAD` (which is committed-only and wrong here — `/duet-impl` never commits, so `HEAD == $START_SHA`). `git diff $START_SHA == git diff HEAD ==` the cumulative work. The work was already staged at the top of Step 3, so new files are in scope.
- **Depth → fan-out at max effort.** This is the *comprehensive* final review: at `/effort max` it must run the 5-angle fan-out (`REVIEW_MODE=fanout`), not `single`. Say so in the invocation ("full review / all angles") so the loaded skill doesn't default to a single pass.

User-visible behavior is one continuous run ending with the verdict. When `/duet-review` finishes, **capture the `Output JSON:` path** from its Step 6 summary (its `verdict.json`) — Step 5 reads the final review's `codebase-fit` findings from that file.

### Step 3b-gate — Verify the embedded review actually ran its cross-review

`/duet-review` owns its own cross-review gate — but that gate is computed by its synthesizer (`koji-duet-synthesize`) and only fires *if that tool runs*. When `/duet-review` executes **inline** (as it just did here), the orchestrator is the one walking its steps, and that skill's single most common failure is reaching its apply step by hand-triaging findings — never running the synthesizer, so no `verdict.json` is produced and the cross-review never fires. From the caller, that bypass is invisible unless we check. So before trusting the verdict, **assert the post-condition** (skip only when `NO_FINAL_REVIEW` made the review legitimately absent):

```bash
if [ "$NO_FINAL_REVIEW" != "1" ]; then
  VERDICT_JSON="<Output JSON path captured from /duet-review's Step 6 summary>"
  GATE=$(python3 -c "
import json, sys
try:
    v = json.load(open('$VERDICT_JSON'))
except Exception:
    print('NO-VERDICT'); sys.exit(0)
req  = v.get('cross_review_required')
done = v.get('cross_review_done')
# Fail CLOSED: a finalized verdict ALWAYS carries both booleans (the synthesizer
# always writes them). Missing/non-bool means the file is not a trustworthy
# verdict — treat as a bypass, never as a pass.
if not isinstance(req, bool) or not isinstance(done, bool):
    print('MALFORMED-VERDICT'); sys.exit(0)
print('GATE-OPEN' if (req and not done) else 'OK')
" 2>/dev/null || echo "NO-VERDICT")

  if [ "$GATE" != "OK" ]; then
    echo "BLOCKED: the embedded /duet-review did not finalize its cross-review gate ($GATE)."
    echo "         A missing/malformed verdict.json, or cross_review_required without"
    echo "         cross_review_done, means the inline review skipped koji-duet-synthesize"
    echo "         and/or its Step 4 — its findings went un-cross-reviewed. Re-run /duet-review"
    echo "         (see below); do NOT proceed to Step 4/5 with this result."
    exit 1   # hard stop — same structural force as /duet-review's own Step 5 gate
  fi
fi
```

The block **hard-exits (`exit 1`) on any non-`OK` state** — missing, malformed, or gate-open — and **fails closed** (a verdict lacking the two boolean keys is treated as a bypass, never waved through), so the stop is a real signal rather than prose the agent might skim past. To recover, **re-invoke `Skill(duet-review)`** on the same working-tree scope and depth (Step 3b above) and let it run all the way through `koji-duet-synthesize` and its Step 4 cross-review to a finalized `verdict.json` (`cross_review_done = true`, no `-PRELIMINARY` suffix). Only a finalized verdict feeds Step 4 reconciliation and Step 5 conventions capture. This is the **caller-side structural backstop**: `/duet-review`'s own gate protects a clean in-skill run; this re-check protects the orchestrator-becomes-executor path, where the gate can be walked around. It mirrors how `/plan-triangulate-review` asserts its own write-gate after driving gstack inline, rather than trusting the sub-process to have stopped.

## Step 4 — Plan reconciliation

Auto-fires at end of every run. Keep the plan file in sync with what
shipped, so `/kick-off` sees the right `status:` and the file records how
the work landed.

Re-read the source plan and edit it directly:

- **Step 3 ran with PASS** (final `/duet-review` AGREE'd / approved): set
  `status: completed`, `implemented: <today>`, `final-review: <verdict>`.
  Add a top blockquote with the reviewer-pass tally (1 foundation gate + `N` post-foundation reviews) + verdict + `git log $START_SHA..HEAD`.
  Append `## Deviations from this plan` only if material drift happened —
  skip on a clean run.
- **Step 3 ran with REJECT**: leave `status` alone (the implementation is
  not complete). Add `executed: <today>`, `final-review: <verdict>`. Top
  blockquote notes: stages executed but the review surfaced unresolved
  findings — see the run dir / final-diff for what's outstanding.
- **Step 3 skipped** (`NO_FINAL_REVIEW` set): leave `status` alone, add
  `executed: <today>` + `pending: review`. Blockquote: stages executed,
  review pending.

**Promise audit annotation** — whenever Step 3a ran (`PROMISE_AUDIT_RAN=1`) AND `PROMISE_AUDIT_GAPS > 0`, append one line to the top blockquote (regardless of PASS / REJECT / pending status):

> Promise audit: `$PROMISE_AUDIT_GAPS` gaps in `$PROMISE_AUDIT_TOTAL` promises — see `$RUN_DIR/promise-audit.json`

The line is informational, not a status change. A clean PASS with promise gaps still records `status: completed` — the gaps are documented as a known deviation, not a blocker (the user already saw them in Step 6 and chose to ship). Skip the line when the audit didn't run or found zero gaps.

**Deferral annotation** — whenever `$RUN_DIR/deferred-findings.md` exists and is non-empty, append one line to the top blockquote (regardless of status):

> Deferred: `<N>` unresolved HIGH across `<M>` gate(s) — see `$RUN_DIR/deferred-findings.md`

Same rule as the promise line: informational, **not a status change**. A clean final `/duet-review` PASS with deferrals still records `status: completed` — the final review is the authority on the cumulative diff (which still contains the deferred code), and the deferrals are documented known-deviations the user triages on return.

On a re-run, replace any prior `/duet-impl` annotation. The edit lands in
the working tree; `/wrap` commits it.

## Step 5 — Conventions capture

Auto-fires at end of every run, **only when `$DOCS_PATH/CODEBASE_CONVENTIONS.md` exists**. Skip silently otherwise (the project predates the codebase-fit artifact, or was never `/koji-init`'d with it). Modeled on `/wrap` Step 2c: one consolidated proposal, one user decision, judgment-gated — never an auto-append.

The `codebase-fit` findings raised across this run's gate reviews and the final `/duet-review` are per-diff observations. Most are one-offs and belong nowhere but the gate report. A few encode a **reusable convention** — a rule the next session would otherwise re-derive or re-litigate. Only those earn a `CODEBASE_CONVENTIONS.md` entry.

1. Collect every `codebase-fit` finding from the run: the gate `findings-*.json` files in `$RUN_DIR`, plus the `codebase-fit` entries in the final `/duet-review`'s `verdict.json` — the `Output JSON:` path captured in Step 3. If `NO_FINAL_REVIEW` was set there is no `verdict.json`; use the gate findings alone.
2. Judge each: is it a *recurring, reusable* convention — would it apply beyond this diff — and is it **not already** recorded in `CODEBASE_CONVENTIONS.md` **or in any doc it lists under `sources:`**? Drop one-off nits, taste, and anything the hub or a linked source already covers.
3. If none survive, skip silently — no prompt.
4. For each surviving finding, decide its **home**: if it belongs in a project convention doc listed under `sources:` (e.g. a naming rule that fits `CONTRIBUTING.md`), it is a **suggestion for the user to add there** — koji never edits a source doc itself. Otherwise it is a **hub entry** for `CODEBASE_CONVENTIONS.md` under one of its three sections. Fire **one** `AskUserQuestion` listing every proposal — each tagged with its home (the `sources:` doc, or the hub section), the one-line rule, and the `file:line` exemplar it cites. The user may accept all, a subset, or decline.
5. On acceptance:
   - **Hub entries** — append under their section in `CODEBASE_CONVENTIONS.md`. If an entry cites a canonical exemplar file not yet in the doc's `covers:` frontmatter, add that file to `covers:` **in the same edit** — `covers:` must always equal the set of cited exemplar files. The edit lands in the working tree; `/wrap` commits it.
   - **Source-doc suggestions** — do **not** edit the source doc. Surface each as a one-line suggestion (e.g. *"consider adding to `CONTRIBUTING.md`: …"*) for the user to apply by hand.

This is the flywheel: `CODEBASE_CONVENTIONS.md` grows from what review actually caught, not from speculative upfront authoring.

## Step 6 — Report

Before printing, compute the code-delta ratio from the **final-review snapshot**. The add/delete counts come from `koji-diff-numstat <start-sha>`, which runs `git diff --numstat "$START_SHA" --` and sums the numeric add/delete columns (machine-readable, locale-independent, and immune to content lines that happen to begin with `--`). Step 3 writes those counts to `$RUN_DIR/final-diff.numstat` at the review point — BEFORE Step 4 reconciliation and Step 5 convention-doc edits — so the ratio reflects the reviewed code, not the later bookkeeping edits. Read from that snapshot when it exists; fall back to a fresh live `koji-diff-numstat "$START_SHA"` only when no snapshot was produced (e.g. `NO_FINAL_REVIEW` with the promise audit also skipped, so neither Step 3 path ran). Either way, capture the helper's exit via command substitution — process substitution would swallow it — so a numstat failure degrades the ratio visibly instead of silently:

```bash
~/.claude/skills/koji/bin/koji-keepawake stop || true   # run concluding — release keep-awake started in Step 2
if [ -s "$RUN_DIR/final-diff.numstat" ]; then           # -s not -f: an empty snapshot (Step-3 write failed; the `> file` redirect truncates even on helper error) falls through to the live fallback instead of reading a bogus "0 0"
  read -r ADDS DELS < "$RUN_DIR/final-diff.numstat"   # final-review snapshot (Step 3)
else
  # No snapshot (neither Step 3 path ran) — compute live now. Command
  # substitution preserves the helper's exit; process substitution would not.
  RATIO_RAW=$(~/.claude/skills/koji/bin/koji-diff-numstat "$START_SHA") \
    || echo 'WARN: code-delta ratio may be inaccurate (koji-diff-numstat failed)' >&2
  read -r ADDS DELS <<< "$RATIO_RAW"
fi
ADDS="${ADDS:-0}"; DELS="${DELS:-0}"   # guard empty reads so the arithmetic below is safe
if [ "$DELS" -gt 0 ]; then
  RATIO=$(python3 -c "print(f'{$ADDS/$DELS:.1f}:1')")
elif [ "$ADDS" -gt 0 ]; then
  RATIO="∞:1"
else
  RATIO="0:0"
fi
```

Then print a markdown summary:

```
duet-impl: <PASS | REJECT>
Plan:      <plan-path>
Gates:     <gate-1> ✓ → <gate-2> ⚠deferred → <gate-3> ✓ (retries: 0, 2, 0)
Code delta: +<ADDS> / −<DELS> (ratio <RATIO>)
Promise audit: <PROMISE_AUDIT_TOTAL> promises checked, <PROMISE_AUDIT_GAPS> gaps
  §<plan-location>: <promise> — no evidence in diff
  §<plan-location>: <promise> — no evidence in diff
Deferred: <N> unresolved high finding(s) — see <RUN_DIR>/deferred-findings.md
  Gate <g>: <file>:<line> [<cat>] <desc>  (why: <reason>)
Final review: <verdict from /duet-review>
Run dir:   <RUN_DIR> (kept for inspection)
```

The `Promise audit:` line prints only when Step 3a ran (`PROMISE_AUDIT_RAN=1`). When zero gaps, print just the one-line summary; when ≥ 1 gap, indent one bulleted line per gap below it (read each gap's `promise` and `plan_location` from `$RUN_DIR/promise-audit.json`). Promise gaps are NOT a status change — they appear alongside the verdict so the user sees both signals and decides whether to ship as-is.

The `Code delta:` line is a meta-signal, not a status change. High ratios (≥ 5:1) are normal for substrate-shipping phases where "add the new path alongside the old one" is the intended pattern — pair it with the `/duet-review` deadcode findings to decide whether the additivity is a foundation play or a smell. A "cleanup" or "refactor" run producing a high ratio is worth a second look. Informational; do not adjust the verdict on the metric alone.

The `Deferred:` block prints only when `$RUN_DIR/deferred-findings.md` is non-empty (one indented line per unresolved HIGH, read from that file). Like promise gaps it is surfaced alongside the verdict, not folded into it — the user triages all deferrals at once on return. Annotate each deferred gate on the `Gates:` line with `⚠deferred`.

## Failure modes

| Symptom | Cause | Mitigation |
|---|---|---|
| Codex review at gate hangs | `--enable web_search_cached` re-introduced, or stdin not closed | Skill explicitly drops both — verify bash not modified |
| Codex exits 124 at a gate | Gate diff too large or `xhigh` exceeded 30-min wall | Re-run asking for a smaller retry budget (`RETRIES=1`, faster fail) and smaller gate scopes |
| Codex quota/rate-limit at a gate | 5-hour session limit depleted mid-run | `koji-codex-classify` returns `QUOTA` (not `[]`) → back off `QUOTA_BACKOFF`s and auto-retry up to `QUOTA_MAX_WAITS`, never a silent PASS. Cap reached → records a deferral and proceeds |
| Gate unresolved after retries + consult | Genuine hard finding | Recorded to `$RUN_DIR/deferred-findings.md`, walk proceeds (never blocks); deferred code stays in the cumulative diff so the end-of-run `/duet-review` re-examines it |
| Implementer-applied fix doesn't compile | Suggested_fix.details was wrong for the actual context | Counts as a retry attempt; codex's next review will flag the new issue. Up to budget |
| Stuck on a "scope" finding (codex says work overshoots phase) | Plan was ambiguous, or implementer interpreted broadly | Consult round usually resolves; if not, record a deferral and proceed |
| Promise audit (Step 3a) times out, returns prose, or emits unparseable JSON | Auditor agent drift, or transient model issue | Write `[]`, log `WARN: promise audit returned no parseable JSON …`, proceed to Step 3b. Audit is a guardrail, not a gate — `/duet-review` still runs |
| Promise audit reports gaps but `/duet-review` PASSes | Reviewers didn't share the audit's specific-contract checklist (the failure mode this audit exists for) | Gaps appear in Step 6 summary and Step 4 reconciliation blockquote. User decides to fix or accept as known deviation |
| `$DOCS_PATH` not set | `/koji-init` never run | Same as `/wrap` |

## Related

- Autonomy principle: [../references/agent-autonomy.md](../references/agent-autonomy.md)
- Gate review prompt: [references/gate-review-prompt.md](references/gate-review-prompt.md)
- Promise audit prompt: [references/promise-audit-prompt.md](references/promise-audit-prompt.md)
- Upstream producer: `/duet-plan` saves the plan files `/duet-impl` consumes
- End-of-run pass: `/duet-review` provides the 2-reviewer adversarial verdict
