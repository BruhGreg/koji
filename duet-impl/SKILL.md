---
description: "Walks a /duet-plan locked plan gate-by-gate with codex single-review per gate, then /duet-review on the full diff. Invocation requires the 'duet' keyword."
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Agent
  - AskUserQuestion
---

# /duet-impl

> Follows the [agent-autonomy principle](../references/agent-autonomy.md): agents resolve technical questions together; users see prompts only for policy choices and unresolved deadlocks.

## When to invoke

Use ONLY when the user explicitly types `/duet-impl`, says "duet impl", "duet-impl", "let's duet implement", or similar — the `duet` keyword is required. Do NOT invoke on casual "let's implement" phrases. On review fail: fix-and-retry up to 2 times, then consult codex once, then escalate to user.

Walks a locked plan from `/duet-plan` (or any plan with `<!-- gate: NAME -->` markers) gate by gate. For each segment: implement the work, then run codex single-review on the segment's diff. At end of the run, run `/duet-review` for the 2-reviewer adversarial pass.

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

Flags:
- `--from-gate <name>` — resume from a specific gate (skip earlier segments; useful for re-runs)
- `--no-final-review` — skip the end-of-run `/duet-review` (rare; only for partial impl)
- `--retries N` — fix-and-retry budget per gate (default 2)

**Codex effort: default xhigh, opt down by saying so.** Codex runs at `xhigh` (~30-min timeout, ~2.5× tokens) for each gate review. Drop to `high` ONLY when the user's invocation phrase signals lighter effort — e.g., "quick gates", "lighter review", "use high effort", "save tokens". Don't downgrade for "the gate diff looks small"; only on explicit user signal. Claude inherits the parent session's effort level.

## Step 1 — Parse the plan

```bash
PLAN_FILE="<resolved-path>"
[ -f "$PLAN_FILE" ] || { echo "ERROR: plan not found: $PLAN_FILE"; exit 1; }

# Capture starting SHA (for diff computation later)
START_SHA=$(git rev-parse --verify HEAD 2>/dev/null) || { echo "ERROR: no commits yet"; exit 1; }
RUN_DIR=$(mktemp -d -t duet-impl-XXXXXX)

# Parse segments
~/.claude/skills/koji/bin/koji-duet-impl-parse --plan "$PLAN_FILE" > "$RUN_DIR/segments.json"
~/.claude/skills/koji/bin/koji-duet-impl-parse --plan "$PLAN_FILE" --summary

# Effort: see "Codex effort" in Flags above for the opt-down rule.
EFFORT="${EFFORT:-xhigh}"
TIMEOUT="${TIMEOUT:-1800}"
RETRIES="${RETRIES:-2}"
echo "Start SHA: $START_SHA | Run dir: $RUN_DIR | Effort: $EFFORT | Retries/gate: $RETRIES"
```

## Step 2 — Walk gates

For each segment in `segments.json` (in order):

### 2a. Skip if `--from-gate` says so

```bash
if [ -n "$FROM_GATE" ] && [ "$gate_name" != "$FROM_GATE" ] && [ "$FROM_GATE_REACHED" != "1" ]; then
  echo "Skipping $gate_name (--from-gate=$FROM_GATE)"
  continue
fi
FROM_GATE_REACHED=1
```

### 2b. Implement the segment

The agent reads `segment.text` and executes the described work using Edit/Write/Bash tools. This is the part where /duet-impl effectively does the coding — the plan tells *what*, the agent figures out *how* (file paths, edits, test runs).

Concretely the agent should:
1. Read the segment text. Identify concrete file edits, new files, dependency changes, test additions.
2. Make the changes via Edit/Write tools.
3. If the segment specifies running tests/commands, run them via Bash.
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
PHASE_TEXT="<segment.text>"  # from segments.json

CODEX_PROMPT="$(awk '/^## Reviewer prompt/,/^## Implementer-side/' "$GATE_PROMPT_TEMPLATE" | sed -n '/^```/,/^```/p' | sed '1d;$d')

(template substitution: replace {gate_name} with $gate_name, {phase_text} with $PHASE_TEXT, {diff} with $(cat $SEGMENT_DIFF_FILE))"

# In practice the agent constructs the prompt inline. Then:
TO=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || echo "")
RAW="$RUN_DIR/codex-${gate_name}-attempt-${attempt}.raw"

if [ -n "$TO" ]; then
  "$TO" "$TIMEOUT" codex exec "$CODEX_PROMPT" \
    -C "$PROJECT_ROOT" -s read-only \
    -c "model_reasoning_effort=\"$EFFORT\"" \
    < /dev/null > "$RAW" 2> "$RAW.err"
else
  codex exec "$CODEX_PROMPT" -C "$PROJECT_ROOT" -s read-only \
    -c "model_reasoning_effort=\"$EFFORT\"" < /dev/null > "$RAW" 2> "$RAW.err"
fi
echo $? > "$RAW.exit"
```

Run this Bash block with **`run_in_background: true`**. Tell the user: *"Gate '$gate_name' attempt $((attempt+1)): codex reviewing in the background."* Then return control. When the notification arrives, proceed to JSON extraction:

```bash
# Extract findings JSON
python3 -c "
import re, json, sys
raw = open('$RAW').read()
m = re.search(r'\[.*\]', raw, re.DOTALL)
if m:
    try: json.loads(m.group(0)); sys.stdout.write(m.group(0)); sys.exit(0)
    except: pass
sys.stdout.write('[]')
" > "$RUN_DIR/findings-${gate_name}-attempt-${attempt}.json"
```

### 2d. Decide PASS / FIX / ESCALATE

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
  # Apply fixes (agent uses Edit tool on each finding's suggested_fix.details)
  apply_high_findings_via_edit_tool "$FINDINGS"
  attempt=$((attempt+1))
  # Loop back to 2c
else
  echo "Gate $gate_name: retry budget exhausted, consulting codex once"
  # Consult round: ask codex to re-examine its findings given that 2 fixes didn't satisfy
  # If consult resolves it (codex agrees fixes are now fine), PASS
  # Otherwise: escalate via AskUserQuestion
fi
```

Per the autonomy principle, the consult-codex round is the "agents try together" step *before* escalating to the user. The consult prompt is:

> *"You flagged these high findings on gate '$gate_name'. The implementer made 2 fix attempts that you still flagged. Either: (a) reconfirm with specific code-level guidance the implementer can apply, or (b) acknowledge if your earlier findings may have been mistaken given the work as-is."*

### 2e. Escalate

If retries exhausted AND consult didn't resolve, use `AskUserQuestion`:

```
Question: "Gate '$gate_name' stuck after $RETRIES retries + 1 consult. How to proceed?"
Options:
  1. "Override — accept the gate and continue"
  2. "Manual fix — pause /duet-impl; user will fix and ask to resume"
  3. "Abort the run"
```

Update `PREV_GATE_SHA` only if option 1 (override) is chosen.

## Step 3 — Final /duet-review

After all segments are processed (or `--from-gate` reaches the end):

```bash
if [ "$NO_FINAL_REVIEW" = "1" ]; then
  echo "Skipping final /duet-review (--no-final-review)"
else
  echo "Running /duet-review on the full diff since $START_SHA..."
  # Invoke /duet-review programmatically — the simplest path is to construct
  # the same diff and run the two reviewers ourselves, or shell out to a
  # mini-runner. For MVP: just tell the user to run /duet-review now (the
  # agent can also invoke it directly via the Skill tool).
  git diff "$START_SHA" -- > "$RUN_DIR/final-diff.patch"
  echo "Full diff at: $RUN_DIR/final-diff.patch"
fi
```

For MVP, the agent invokes `/duet-review` as the next action (not via subprocess) — user-visible behavior is one continuous run ending with the verdict.

## Step 4 — Report

Print a markdown summary:

```
duet-impl: <PASS | REJECT | ESCALATED>
Plan:      <plan-path>
Gates:     <gate-1> ✓ → <gate-2> ✓ → <gate-3> ✓ (retries: 0, 1, 0)
Final review: <verdict from /duet-review>
Run dir:   <RUN_DIR> (kept for inspection)
```

If any gate escalated, mention which one and how the user resolved it.

## Failure modes

| Symptom | Cause | Mitigation |
|---|---|---|
| Plan parser returns 0 segments | Plan file is empty, or only gate markers with no text | Surface error, exit |
| Codex review at gate hangs | `--enable web_search_cached` re-introduced, or stdin not closed | Skill explicitly drops both — verify bash not modified |
| Codex exits 124 at a gate | Gate diff too large or `xhigh` exceeded 30-min wall | Re-run with `--retries 1` (faster fail) and smaller gate scopes |
| Implementer-applied fix doesn't compile | Suggested_fix.details was wrong for the actual context | Counts as a retry attempt; codex's next review will flag the new issue. Up to budget |
| Stuck on a "scope" finding (codex says work overshoots phase) | Plan was ambiguous, or implementer interpreted broadly | Consult round usually resolves; if not, escalate to user |
| `$DOCS_PATH` not set | `/koji-init` never run | Same as `/wrap` |

## Related

- Autonomy principle: [../references/agent-autonomy.md](../references/agent-autonomy.md)
- Gate review prompt: [references/gate-review-prompt.md](references/gate-review-prompt.md)
- Plan parser: [koji/bin/koji-duet-impl-parse](../bin/koji-duet-impl-parse)
- Upstream producer: `/duet-plan` writes the locked plan files `/duet-impl` consumes
- End-of-run pass: `/duet-review` provides the 2-reviewer adversarial verdict
