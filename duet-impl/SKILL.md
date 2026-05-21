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
---

# /duet-impl

> Follows the [agent-autonomy principle](../references/agent-autonomy.md): agents resolve technical questions together; users see prompts only for policy choices and unresolved deadlocks.

## When to invoke

Use ONLY when the user explicitly types `/duet-impl`, says "duet impl", "duet-impl", "let's duet implement", or similar — the `duet` keyword is required. Do NOT invoke on casual "let's implement" phrases. On review fail: fix-and-retry up to 2 times, then consult codex once, then escalate to user.

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

Flags:
- `--from-gate <name>` — resume from a specific gate (skip earlier segments; useful for re-runs)
- `--no-final-review` — skip the end-of-run `/duet-review` (rare; only for partial impl)
- `--retries N` — fix-and-retry budget per gate (default 2)

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
echo "Start SHA: $START_SHA | Run dir: $RUN_DIR | Effort: $EFFORT | Retries/gate: $RETRIES"
```

Then **read the plan** (via the `Read` tool), identify the natural checkpoint boundaries per the strategy above, and announce the proposed plan in one sentence before Step 2 begins. State explicitly: foundation gate (yes/no), `N`, the positions, and the total reviewer-pass count. Example:

> "Plan has 2 foundation steps + 11 post-foundation steps. Proposing **foundation gate (codex single after Step 2)** + **`N=2` post-foundation reviews**: mid-term codex single after Step 7, final `/duet-review` after Step 11. **Total: 3 reviewer passes** (1 foundation + 2 post-foundation, the second of which IS the duet-review)."

The user can redirect before any work starts. Each checkpoint becomes a "segment" used by Step 2 — checkpoint name + the plan text governing that segment's scope. Note that the FINAL segment's review is the `/duet-review` itself (Step 3 below), so Step 2 walks only the foundation gate + the `1/N … (N-1)/N` codex singles — Step 2 does NOT execute a codex single at position `N/N`.

**Create the progress task list.** With the checkpoints fixed, call `TaskCreate` to lay out the walk as a task list — one task per segment in plan order, named for its checkpoint (e.g. `Foundation: types + scaffolding`, `Segment 2: handlers`), plus a final task for the `/duet-review` pass. This is required, not optional: it is the live checklist the user watches while the implementation runs. Step 2 keeps it current.

## Step 2 — Walk codex-reviewed checkpoints

For each checkpoint that has a codex single-review attached (foundation gate + the `1/N … (N-1)/N` post-foundation positions), in order:

> NOTE: the `N/N` position is the final `/duet-review`, handled by Step 3 — **do not** schedule a codex single-review at end-of-plan. Step 2 stops one position short of the end.

**Keep the task list current.** As you walk each checkpoint: `TaskUpdate` its task to `in_progress` when its segment work begins (2b), and to `completed` when its gate review passes (2d PASS). Mark the final `/duet-review` task `completed` once Step 3's verdict is in. The user is watching this checklist — it must track the real state of the walk.

### 2a. Skip if `--from-gate` says so

```bash
if [ -n "$FROM_GATE" ] && [ "$gate_name" != "$FROM_GATE" ] && [ "$FROM_GATE_REACHED" != "1" ]; then
  echo "Skipping $gate_name (--from-gate=$FROM_GATE)"
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

For MVP, the agent invokes `/duet-review` as the next action (not via subprocess) — user-visible behavior is one continuous run ending with the verdict. When `/duet-review` finishes, **capture the `Output JSON:` path** from its Step 6 summary (its `verdict.json`) — Step 5 reads the final review's `codebase-fit` findings from that file.

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
- **Step 3 ran with REJECT or ESCALATED**: leave `status` alone (the
  implementation is not complete). Add `executed: <today>`,
  `final-review: <verdict>`. Top blockquote notes: stages executed but
  review surfaced unresolved findings (REJECT) or required escalation
  (ESCALATED) — see the run dir / final-diff for what's outstanding.
- **Step 3 skipped** (`--no-final-review`): leave `status` alone, add
  `executed: <today>` + `pending: review`. Blockquote: stages executed,
  review pending.

On a re-run, replace any prior `/duet-impl` annotation. The edit lands in
the working tree; `/wrap` commits it.

## Step 5 — Conventions capture

Auto-fires at end of every run, **only when `$DOCS_PATH/CODEBASE_CONVENTIONS.md` exists**. Skip silently otherwise (the project predates the codebase-fit artifact, or was never `/koji-init`'d with it). Modeled on `/wrap` Step 2c: one consolidated proposal, one user decision, judgment-gated — never an auto-append.

The `codebase-fit` findings raised across this run's gate reviews and the final `/duet-review` are per-diff observations. Most are one-offs and belong nowhere but the gate report. A few encode a **reusable convention** — a rule the next session would otherwise re-derive or re-litigate. Only those earn a `CODEBASE_CONVENTIONS.md` entry.

1. Collect every `codebase-fit` finding from the run: the gate `findings-*.json` files in `$RUN_DIR`, plus the `codebase-fit` entries in the final `/duet-review`'s `verdict.json` — the `Output JSON:` path captured in Step 3. If `--no-final-review` was set there is no `verdict.json`; use the gate findings alone.
2. Judge each: is it a *recurring, reusable* convention — would it apply beyond this diff — and is it **not already** recorded in `CODEBASE_CONVENTIONS.md` **or in any doc it lists under `sources:`**? Drop one-off nits, taste, and anything the hub or a linked source already covers.
3. If none survive, skip silently — no prompt.
4. For each surviving finding, decide its **home**: if it belongs in a project convention doc listed under `sources:` (e.g. a naming rule that fits `CONTRIBUTING.md`), it is a **suggestion for the user to add there** — koji never edits a source doc itself. Otherwise it is a **hub entry** for `CODEBASE_CONVENTIONS.md` under one of its three sections. Fire **one** `AskUserQuestion` listing every proposal — each tagged with its home (the `sources:` doc, or the hub section), the one-line rule, and the `file:line` exemplar it cites. The user may accept all, a subset, or decline.
5. On acceptance:
   - **Hub entries** — append under their section in `CODEBASE_CONVENTIONS.md`. If an entry cites a canonical exemplar file not yet in the doc's `covers:` frontmatter, add that file to `covers:` **in the same edit** — `covers:` must always equal the set of cited exemplar files. The edit lands in the working tree; `/wrap` commits it.
   - **Source-doc suggestions** — do **not** edit the source doc. Surface each as a one-line suggestion (e.g. *"consider adding to `CONTRIBUTING.md`: …"*) for the user to apply by hand.

This is the flywheel: `CODEBASE_CONVENTIONS.md` grows from what review actually caught, not from speculative upfront authoring.

## Step 6 — Report

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
| Codex review at gate hangs | `--enable web_search_cached` re-introduced, or stdin not closed | Skill explicitly drops both — verify bash not modified |
| Codex exits 124 at a gate | Gate diff too large or `xhigh` exceeded 30-min wall | Re-run with `--retries 1` (faster fail) and smaller gate scopes |
| Implementer-applied fix doesn't compile | Suggested_fix.details was wrong for the actual context | Counts as a retry attempt; codex's next review will flag the new issue. Up to budget |
| Stuck on a "scope" finding (codex says work overshoots phase) | Plan was ambiguous, or implementer interpreted broadly | Consult round usually resolves; if not, escalate to user |
| `$DOCS_PATH` not set | `/koji-init` never run | Same as `/wrap` |

## Related

- Autonomy principle: [../references/agent-autonomy.md](../references/agent-autonomy.md)
- Gate review prompt: [references/gate-review-prompt.md](references/gate-review-prompt.md)
- Upstream producer: `/duet-plan` saves the plan files `/duet-impl` consumes
- End-of-run pass: `/duet-review` provides the 2-reviewer adversarial verdict
