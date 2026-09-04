---
description: "Walks a saved plan: 1 foundation gate + N post-foundation gate reviews where the Nth IS the final /duet-review; who reviews (codex, Claude, both, or Claude-then-codex) is asked at run start. Invocation requires the 'duet' keyword."
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

Use ONLY when the user explicitly types `/duet-impl`, says "duet impl", "duet-impl", "let's duet implement", or similar — the `duet` keyword is required. Do NOT invoke on casual "let's implement" phrases. On review fail: fix-and-retry up to 2 times, then consult the gate reviewer(s) once, then record a deferral and proceed — the loop never blocks on a modal prompt.

Walks a saved plan from `/duet-plan` (or any structured plan). **Total reviewer passes = 1 foundation gate + N post-foundation reviews, where the Nth IS the final `/duet-review`** — never schedule a gate review immediately before the duet-review (it already runs both families + cross-review; a back-to-back gate review is duplicate work). Who reviews each gate — codex, a fresh-context Claude, both, or Claude with a codex confirmation — is the **duet setup** asked at run start. N is typically 1 (small/mechanical) or 2 (medium, default); rarely 3 (large/dense). See **Review checkpoint strategy** below for placement.

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
- **Skip the final review** → `NO_FINAL_REVIEW`. The run ends with a `/duet-review` by default. If the user only wants a partial implementation with no end-of-run review ("don't run the final review", "skip duet-review", "partial impl only"), set `NO_FINAL_REVIEW=1`. Note: the last intermediate gate then becomes the run's de-facto final review, yet it still follows the gate rule (a codex quota substitutes a fresh-context Claude reviewer). If you skip the duet-review, the run's last verdict may carry no codex signal — the Step 6 report says which backend reviewed each gate.
- **Skip the promise audit** → `NO_PROMISE_AUDIT`. The cumulative promise audit (Step 3a) runs by default. If the user opts out ("skip the promise audit", "no promise check"), set `NO_PROMISE_AUDIT=1`. It is also implied whenever `NO_FINAL_REVIEW=1`.
- **Retry budget per gate** → `RETRIES`. Each gate gets 2 fix-and-retry attempts by default. If the user wants a different budget ("one retry per gate", "fail fast", "3 retries"), set `RETRIES` to that number.
- **Codex quota back-off** → `QUOTA_BACKOFF` (interval seconds, default 900) / `QUOTA_MAX_WAITS` (cap, default 20 ≈ 5h). These govern **only the final gate** — the embedded `/duet-review` — which backs off and auto-resumes when the 5-hour window restores. At gates 1..N-1 a codex quota reply (or a start failure) does **not** wait: the gate falls to the other family per the strategy — a fresh-context Claude substitute under `codex`, Claude alone under `both`, the Claude verdict alone at a `claude-then-codex` confirm — and the next gate tries codex again (Step 2c). Tune via intent ("retry every 10 minutes", "give up after an hour", "wait all night") — carry the phrase into the final `/duet-review` invocation.
- **Duet setup from the phrase** → an overlay for the setup tuple. Fields the phrase states ("with both reviewers", "codex only", "at max", "quick gates" → high, "claude reviewer on sonnet") are set; when the phrase fixes the strategy there is no setup question at all. See "Duet setup" below.

**Stuck gates never block (default, no toggle).** When a gate can't clear after `RETRIES` + the consult round, the unresolved HIGH is recorded as a **deferral** — appended to `$RUN_DIR/deferred-findings.md` and the Step 6 report — and the walk proceeds. The deferred code stays in the cumulative diff, so the end-of-run `/duet-review` re-examines it. This is the only posture at gates 1..N-1: they never freeze on a modal prompt, so the walk itself can run unattended. (The final `/duet-review` and Step 5's conventions capture may still ask — those are policy prompts under the autonomy principle, not gate decisions.) Nothing is silently dropped — every deferral is a documented decision surfaced at end-of-run.

## Duet setup

Who reviews each gate, at what effort, on which Claude model is decided **at the start of this run** — one question, remembered — never from `.koji.yaml`. Full contract (the tuple, the resolution order, the dialog, agent definitions, mapping table, read-only clause, slot rule, quota rule): [`../references/reviewer-backend.md`](../references/reviewer-backend.md). Resolve it **before Step 1's block**: baseline (last pick, else defaults) → phrase overlay → if the strategy is still open, ask (*reuse* the last setup, or the three-question dialog) → `EFFECTIVE`. The four strategies at gates 1..N-1 (gate N is the embedded `/duet-review`, which receives the same tuple):

- **`codex`** (default) — codex reviews the gate; a codex quota/error substitutes a fresh-context Claude for that gate.
- **`claude`** — a **fresh-context Claude subagent** (never a fork) reviews the gate. Zero codex until the final review, which is Claude-B too — same-model caveat in the report.
- **`claude-then-codex`** — Claude reviews the gate; when Claude finds no HIGH, **one codex call confirms the pass on the same snapshot** before the gate passes. Codex HIGHs go into the fix loop like any others; the next attempt starts with Claude again. Cheap iteration, one expensive call per pass.
- **`both`** — codex **and** a fresh-context Claude review the gate in parallel on the same prompt; findings merge through `koji-duet-synthesize`, and the two families cross-review what only one of them raised before the HIGH count is taken. Most calls, strongest signal.

Codex runs at the tuple's codex effort (`max` / `xhigh` / `high`; ~30-min timeout at the top tiers); Claude reviewers run as `koji-reviewer-<effort>` agents. `TIMEOUT` may be lowered to `900` when the effort is `high`.

## Review checkpoint strategy

Two kinds of review checkpoint, separately budgeted:

1. **Foundation gate** — one gate review after foundation steps land (scaffolding with no standalone behavior: new types, trait-shape changes, mechanical stubs that just make the workspace compile). Validates the base before downstream depends on it. Skip only when the plan has no distinct foundation phase.
2. **Post-foundation reviews** — `N` reviews distributed across the remaining work at fractional positions `1/N, 2/N, …, N/N`. **The `N/N` position IS the final `/duet-review`** (two reviewers + cross-review); the intermediate `1/N … (N-1)/N` positions are gate reviews. So `N` includes the duet-review in its count, NOT in addition to it.

**Total reviewer passes = 1 (foundation gate) + N (post-foundation reviews, the last of which is the duet-review).**

Pick `N` by weighting the *post-foundation* work — LoC density, risk inflections, and how much real reasoning each step requires. Mechanical pattern-application counts for less; cross-layer or pattern-establishing steps count for more. Default by size:

| Post-foundation work | `N` | Positions | Total passes (incl. foundation) |
|---|---|---|---|
| Small / mostly mechanical (<5 PRs) | 1 | duet-review at end only | 2 |
| Medium (default) | 2 | gate review at 1/2, duet-review at 2/2 | 3 |
| Large or dense (>10 PRs, multiple risk inflections) | 3 | gate reviews at 1/3 + 2/3, duet-review at 3/3 | 4 |

**Position is a judgment call, not strict math.** Slide each fractional checkpoint a step or two to land it on a natural seam — right after a pattern is established, right before a cross-layer transition, right before a risk inflection. Mechanical/mindless steps lower the weight; heavy-reasoning steps raise it. For a 12-step plan with `s1+s2` foundation and 10 steps remaining at `N=2`, the mid-term gate review would land at ~`s2 + 5 = s7`, but it's fine to slide to `s6` or `s8` if the natural seam is there.

**Anti-patterns:**

1. **One gate per step.** Codex single-review at every step is expensive, fatigues the reviewer, and produces noise that obscures high-signal findings. Reserve exhaustive coverage for the final `/duet-review`.
2. **A gate review immediately before the final `/duet-review`.** The duet-review already runs codex + cross-review; a back-to-back single-review is duplicate work. The final reviewer pass IS the duet-review — there is no separate "Gate N gate review + then duet-review" pattern. Schedule `N` total post-foundation reviews, not `N+1`.
3. **Treating "gate count" as a flat number.** Don't think "3 gates means 3 gate reviews plus a duet-review at the end." Think "1 foundation gate + N post-foundation reviews, the last of which is the duet-review." Total reviewer passes is the explicit sum.

For plans with `<!-- gate: NAME -->` markers, honor them as explicit boundaries. For plans without markers (the common case), derive boundaries from structure: numbered `### Step N` headings, sectional H2/H3 breaks, or the agent's reading of natural cohesion.

## Step 1 — Identify checkpoints from the plan

The agent reads the plan and decides checkpoint placement per the **Review checkpoint strategy** above. This is a judgment call from plan structure — no parser tool.

```bash
PLAN_FILE="<resolved-path>"
[ -f "$PLAN_FILE" ] || { echo "ERROR: plan not found: $PLAN_FILE"; exit 1; }

# Capture starting SHA (for diff computation later)
START_SHA=$(git rev-parse --verify HEAD 2>/dev/null) || { echo "ERROR: no commits yet"; exit 1; }
RUN_DIR=$(mktemp -d -t duet-impl-XXXXXX)

# Duet setup (see "Duet setup" above). EFFECTIVE was resolved just before this
# block (phrase overlay → reuse prompt → dialog → defaults); substitute it here.
# Validate, save as the last pick, record for the run: every later block
# re-reads $RUN_DIR/duet-setup rather than trusting a variable to survive.
KDS=~/.claude/skills/koji/bin/koji-duet-setup
TUPLE=$("$KDS" validate "<EFFECTIVE tuple>") || exit 1
~/.claude/skills/koji/bin/koji-config set duet_setup "$TUPLE"
printf '%s\n' "$TUPLE" > "$RUN_DIR/duet-setup"
STRATEGY=$("$KDS" field "$TUPLE" 1)        # both | claude-then-codex | codex | claude
EFFORT=$("$KDS" field "$TUPLE" 2)          # codex model_reasoning_effort
CLAUDE_EFFORT=$("$KDS" field "$TUPLE" 3)   # koji-reviewer-<effort> agent for the Claude legs; inherit → general-purpose
CLAUDE_MODEL=$("$KDS" field "$TUPLE" 4)    # Agent `model` param; inherit → omit
TIMEOUT="${TIMEOUT:-1800}"
RETRIES="${RETRIES:-2}"
# Gate leg for gates 1..N-1 (gate N is the embedded /duet-review, handed the same tuple).
GATE_LEG=$(~/.claude/skills/koji/bin/koji-duet-backend impl-gate "$RUN_DIR/duet-setup") || exit 1   # codex | claude | both
# Intent-set vars (see "Intent, not flags" above). Initialized here so the
# reads below run cleanly under set -u even when no intent was signalled.
FROM_GATE="${FROM_GATE:-}"           # gate name to resume from (Step 2a)
FROM_GATE_REACHED="${FROM_GATE_REACHED:-}"  # loop state for the FROM_GATE resume skip (Step 2a)
NO_FINAL_REVIEW="${NO_FINAL_REVIEW:-}"      # skip end-of-run /duet-review (Step 3b)
NO_PROMISE_AUDIT="${NO_PROMISE_AUDIT:-}"    # skip the promise audit (Step 3a)
QUOTA_BACKOFF="${QUOTA_BACKOFF:-900}"        # codex quota back-off interval (s) — final gate (/duet-review) only
QUOTA_MAX_WAITS="${QUOTA_MAX_WAITS:-20}"     # cap on quota back-off retries — final gate only (~5h)
B_RETRIED="${B_RETRIED:-0}"                  # Claude-leg malformed-reply retry used at this gate attempt (0/1)
echo "Start SHA: $START_SHA | Run dir: $RUN_DIR | Retries/gate: $RETRIES | Duet setup: $("$KDS" summary "$TUPLE") | Gate leg: $GATE_LEG"
```

Then **read the plan** (via the `Read` tool), identify the natural checkpoint boundaries per the strategy above, and announce the proposed plan in one sentence before Step 2 begins. State explicitly: foundation gate (yes/no), `N`, the positions, and the total reviewer-pass count. Example:

> "Plan has 2 foundation steps + 11 post-foundation steps. Proposing **foundation gate (gate review after Step 2)** + **`N=2` post-foundation reviews**: mid-term gate review after Step 7, final `/duet-review` after Step 11. **Total: 3 reviewer passes** (1 foundation + 2 post-foundation, the second of which IS the duet-review)."

The user can redirect before any work starts. Each checkpoint becomes a "segment" used by Step 2 — checkpoint name + the plan text governing that segment's scope. Note that the FINAL segment's review is the `/duet-review` itself (Step 3 below), so Step 2 walks only the foundation gate + the `1/N … (N-1)/N` gate reviews — Step 2 does NOT execute a gate review at position `N/N`.

**Create the progress task list.** With the checkpoints fixed, call `TaskCreate` to lay out the walk as a task list — one task per segment in plan order, named for its checkpoint (e.g. `Foundation: types + scaffolding`, `Segment 2: handlers`), plus a final task for the `/duet-review` pass. This is required, not optional: it is the live checklist the user watches while the implementation runs. Step 2 keeps it current.

## Step 2 — Walk gate-reviewed checkpoints

**Keep the machine awake for the walk** (once, before the per-checkpoint loop): the gate reviews dispatch as background tasks across many turns, so the user can step away. Refcounted + self-cleaning; never touches a caffeinate the user started. Torn down in Step 6. No `/wrap` dependency.

```bash
~/.claude/skills/koji/bin/koji-keepawake start || true
```

For each checkpoint that has a gate review attached (foundation gate + the `1/N … (N-1)/N` post-foundation positions), in order:

> NOTE: the `N/N` position is the final `/duet-review`, handled by Step 3 — **do not** schedule a gate review at end-of-plan. Step 2 stops one position short of the end.

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
4. Fix the segment's diff base:
   ```bash
   # PREV_GATE_SHA is the previous gate's snapshot commit — 2d creates it with
   # commit-tree (a dangling commit; HEAD never moves during the walk) and writes
   # it to $RUN_DIR/gate-<prev>-snapshot.txt. Fresh shell: read that file rather
   # than trusting a remembered variable. First gate: START_SHA.
   SEGMENT_START_SHA="${PREV_GATE_SHA:-$START_SHA}"
   # Filesystem-safe gate id for every $RUN_DIR file keyed by this gate: a plan
   # marker like `<!-- gate: API / UI -->` is a legal name but not a legal path.
   # The cksum suffix keeps ids unique: "API / UI" and "API---UI" must not share files.
   gate_id="$(printf '%s' "$gate_name" | tr -c 'A-Za-z0-9._-' '-')-$(printf '%s' "$gate_name" | cksum | cut -d' ' -f1)"
   ```
5. **Docstrings and comments describe the code, not its history.** Write them to open-source product standard: what the function, class, or module does, what it needs, what it returns, and any constraint a caller must know. Usage examples are welcome where the language's docstring convention supports them (Dart `///` blocks, Python doctests, Rust `///` examples, Go `Example` functions) — they show how to call the thing, not how it was built. Never include dates, version numbers, plan or gate names, reviewer references, "per X", "see plan Y", or why a decision was made. A "why" that explains a non-obvious constraint in the code itself ("must run before X because Y holds the lock") is about the code and stays. Provenance belongs in the commit message and the session log. **Before staging, re-read every docstring and comment this segment added or changed against that rule and fix them on the spot** — this self-check is the enforcement; the gate reviewer only backstops it at `medium`.

**Stage everything** (`git add -A`) after segment work. 2c stages again before it diffs, but an untracked new file is invisible to `git diff` until it is in the index, and the gate must see the principal output of the segment.

### 2c. Gate review at this gate (background)

Set up the attempt — common to every strategy. The backend record decides the leg, and a pending confirm is **resumable**: it is never re-armed and never re-snapshotted, so codex reviews exactly what Claude reviewed.

```bash
REC="$RUN_DIR/gate-${gate_id}-attempt-${attempt}-backend.txt"
SEGMENT_DIFF_FILE="$RUN_DIR/diff-${gate_id}-attempt-${attempt}.patch"
PROMPT_TXT="$RUN_DIR/prompt-${gate_id}-attempt-${attempt}.txt"
RAW="$RUN_DIR/codex-${gate_id}-attempt-${attempt}.raw"
FINDINGS="$RUN_DIR/findings-${gate_id}-attempt-${attempt}.json"          # the slot 2d reads — every strategy ends here
A_SLOT="$RUN_DIR/findings-${gate_id}-attempt-${attempt}-claude.json"   # both: Claude's family slot · claude-then-codex: the archived Claude array
B_SLOT="$RUN_DIR/findings-${gate_id}-attempt-${attempt}-codex.json"    # both: codex's family slot
V="$RUN_DIR/gate-${gate_id}-attempt-${attempt}-verdict.json"           # both: the merged verdict
GATE_PROMPT_TEMPLATE="$KOJI_SKILLS/duet-impl/references/gate-review-prompt.md"
B_RETRIED=0
case "$(cat "$REC" 2>/dev/null)" in
  claude+codex-confirm)
    # Confirm re-entry (2d armed it): codex must review the SAME snapshot Claude
    # reviewed, and the fallback needs Claude's archived array. Reuse; never recompute.
    [ -s "$SEGMENT_DIFF_FILE" ] && [ -s "$PROMPT_TXT" ] && ~/.claude/skills/koji/bin/koji-duet-findings-check "$A_SLOT" \
      || { echo "ERROR: confirm re-entry without the attempt's diff/prompt/validated Claude archive — run state lost"; exit 1; }
    LEG=codex ;;
  *)
    git add -A                                                # MANDATORY: an untracked new file is invisible to git diff until staged
    git diff "$SEGMENT_START_SHA" -- > "$SEGMENT_DIFF_FILE"   # working tree vs the previous gate's snapshot (2d) or START_SHA — segment-local
    # Fill the "## Reviewer prompt" template from $GATE_PROMPT_TEMPLATE inline —
    # {gate_name} → $gate_name, {phase_text} → the plan text for this gate, {diff} →
    # the contents of $SEGMENT_DIFF_FILE — into $GATE_PROMPT, then write it ONCE per
    # attempt. Every leg reads this file; the backend never changes the prompt.
    # printf is a builtin (no argv ceiling — a gate diff can exceed ARG_MAX).
    printf '%s\n' "$GATE_PROMPT" > "$PROMPT_TXT"
    # The run's setup file is authoritative; a missing file is lost run state (exit 3), never "codex".
    LEG=$(~/.claude/skills/koji/bin/koji-duet-backend impl-gate "$RUN_DIR/duet-setup") || exit 1   # codex | claude | both
    printf '%s\n' "$LEG" > "$REC" ;;
esac
echo "Gate $gate_name attempt $((attempt+1)): leg = $LEG"
```

**Run the leg(s) matching `LEG`.** `codex` → the codex leg. `claude` → the Claude leg. `both` → **both legs in parallel** on the same `$PROMPT_TXT`, then the merge below. Every leg reads `$PROMPT_TXT`; the Claude leg appends the read-only clause. **A slot file exists only when it holds a validated array**: every array is written to `<slot>.tmp`, checked with `~/.claude/skills/koji/bin/koji-duet-findings-check`, and renamed into place — the classifier writes `[]` on `EMPTY`, and a parseable-but-malformed array must never sit where 2d reads it as a clean review. The same-file-slot rule and the `both` two-slot exception are in [`../references/reviewer-backend.md`](../references/reviewer-backend.md).

#### 2c — codex leg (`LEG=codex`, a `both` half, or the confirm step)

```bash
TO=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || echo "")
# Fresh shell: effort from the run's setup file, never a Step 1 variable.
EFFORT=$(~/.claude/skills/koji/bin/koji-duet-setup field "$(head -n1 "$RUN_DIR/duet-setup")" 2) || exit 1

# Prompt file → codex stdin (`-`). A regular-file redirect EOFs immediately, so
# codex never blocks on stdin. `-` must be the ONLY positional.
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

Run this Bash block with **`run_in_background: true`**. Tell the user: *"Gate '$gate_name' attempt $((attempt+1)): codex reviewing in the background."* Then return control. When the notification arrives, **classify into a temp file and publish only a validated array**:

```bash
SLOT="$FINDINGS"; [ "$(cat "$REC")" = "both" ] && SLOT="$B_SLOT"
rm -f "$SLOT.tmp"
STATE=$(~/.claude/skills/koji/bin/koji-codex-classify "$RAW" "$RAW.err" "$RAW.exit" --json-out "$SLOT.tmp")
case "$STATE" in
  OK) if ~/.claude/skills/koji/bin/koji-duet-findings-check "$SLOT.tmp"; then mv "$SLOT.tmp" "$SLOT"; else rm -f "$SLOT.tmp"; STATE=MALFORMED; fi ;;
  *)  rm -f "$SLOT.tmp" ;;   # a codex reply that is not a findings array is not a review — the classifier's [] on EMPTY never reaches the slot
esac
echo "Gate $gate_name attempt $((attempt+1)): codex state = $STATE (record: $(cat "$REC"))"
```

Branch on `$STATE`, by record:

- **`OK`** → the slot is published. Record `codex` or `claude+codex-confirm` → proceed to 2d. Record `both` → the `both` merge below.
- **`MALFORMED`** (array failed the check) → when `B_RETRIED=0`, set `B_RETRIED=1` and re-dispatch the codex leg once with *"Your last response was not a JSON array of the requested shape — re-output ONLY the array, `[]` if none."* appended to the prompt; a second failure → treat as `ERROR` below.
- **`QUOTA` / `ERROR` / `TIMEOUT` / `EMPTY`** — **substitute, never `[]`.** Gates 1..N-1 are not final, so there is no back-off here (only gate N — the embedded `/duet-review` — waits on quota). By record:
  - **`codex`** → log `⚠ codex $STATE — gate $gate_name reviewed by fresh-context Claude`, overwrite the record — `printf 'codex-quota-substituted\n'` for `QUOTA`, `printf 'codex-error-substituted\n'` for the other three — and run the **Claude leg below** for this same attempt on the same `$PROMPT_TXT`. Substitution is per-review, not a mode switch: the next gate tries codex again, since the 5-hour window may have restored.
  - **`both`** → the codex side is **unavailable** for this attempt; the Claude leg is already running or in — no substitution. Continue at the `both` merge below.
  - **`claude+codex-confirm`** → Claude confirming Claude is nothing, so no substitution: `printf 'claude+codex-unavailable\n' > "$REC"`, then `~/.claude/skills/koji/bin/koji-duet-findings-check "$A_SLOT" && cp "$A_SLOT" "$FINDINGS"` (the archived Claude array, re-validated — 2d needs a real array, never `[]`; a failed check here is lost state: `exit 1`), log `⚠ codex $STATE at the confirm step — gate $gate_name passes on the Claude verdict alone`, and proceed to 2d. Non-final; the walk never blocks; Step 6 names the gate.

#### 2c — Claude leg (`LEG=claude`, a `both` half, or a codex substitution)

Record the tree state first — the Claude backend has no `-s read-only` sandbox, only an instruction, so the run detects (not prevents) a reviewer that edits:

```bash
: "${RAW:?RAW unset — re-substitute it in this block}"   # an empty prefix would write ".fp" into the repo root
~/.claude/skills/koji/bin/koji-tree-fingerprint > "$RAW.fp"   # compared on collection
```

**Call the `Agent` tool** — a literal tool call; do not narrate "spawning a reviewer" and write the findings yourself. The reviewer runs in a **fresh Agent context, never a fork** — a fork inherits the implementer's view of the segment, which is exactly the blind spot a gate review exists to catch.

- `subagent_type`: `koji-reviewer-$CLAUDE_EFFORT` (e.g. `koji-reviewer-max`) when `$CLAUDE_EFFORT` is not `inherit`; otherwise `general-purpose`. Unknown type (agents not installed) → print `⚠ koji-reviewer-<x> not installed — run koji setup; falling back to general-purpose (inherit effort)`, `touch "$RUN_DIR/claude-effort-fallback"`, re-dispatch with `general-purpose`.
- `description`: `Duet-impl gate '<gate_name>' attempt <attempt+1>: Claude review`
- `model`: **omit this parameter** when `$CLAUDE_MODEL` is `inherit`; otherwise pass its value (`fable` / `opus` / `sonnet`)
- `prompt`: the contents of `$PROMPT_TXT` — the same filled prompt the codex leg reads — followed by the **read-only clause** from `../references/reviewer-backend.md`
- `run_in_background`: `true`

Tell the user: *"Gate '$gate_name' attempt $((attempt+1)): Claude reviewing in the background."* Then return control. When the notification arrives, extract the JSON array from the response, Write it to `<slot>.tmp` — the slot is `$A_SLOT` when the record is `both`, else `$FINDINGS` — run `~/.claude/skills/koji/bin/koji-duet-findings-check` on it, and `mv` it into place only when the check passes; also Write the raw response to `$RAW.claude.txt` so a bad extraction can be debugged. **Do not run `koji-codex-classify` on it** — its quota-marker scan over review prose would misfire — and there is no `.exit` file to read. Then compare the tree fingerprint:

```bash
FP_NOW=$(~/.claude/skills/koji/bin/koji-tree-fingerprint)
[ "$FP_NOW" = "$(cat "$RAW.fp" 2>/dev/null)" ] \
  || echo "⚠ working tree changed while a read-only reviewer was in flight (reviewer or concurrent work) — review snapshot may be stale"
```

If the response has **no parseable array, or the array fails the check**: when `B_RETRIED=0`, set `B_RETRIED=1` and re-dispatch the same Agent call once with the reminder *"Your last response was not a JSON array of the requested shape — re-output ONLY the array, `[]` if none."* On a second failure the Claude reviewer is **unavailable** for this attempt — `rm -f` the temp, never write `[]`. Record `claude` or a `codex-*-substituted` record → record a deferral (reason *"reviewer unavailable — malformed reply ×2"*, template in 2d) and proceed to the next gate — do **not** run 2d. Record `both` → continue at the merge below with the Claude side unavailable. Otherwise proceed to 2d.

#### 2c — `both`: collect, merge, cross-review

Each leg notifies on its own. **A leg that is merely pending is not unavailable**: after the first notification, if the other leg has no terminal result yet (codex: no `$RAW.exit` classified; Claude: no result), confirm what arrived and return control — the next notification re-invokes you. Degrade only on a terminal failure (codex non-`OK` after its retry; Claude malformed ×2). Once both families have a terminal result:

- **`$A_SLOT` and `$B_SLOT` both exist** → synthesize (below).
- **Exactly one exists and the other family failed terminally** → publish the terminal record **first**, then the slot: `printf 'both:claude-only\n' > "$REC"` (codex failed) or `printf 'both:codex-only\n' > "$REC"` (Claude failed), then `cp "$A_SLOT" "$FINDINGS"` / `cp "$B_SLOT" "$FINDINGS"`. Print `⚠ <family> unavailable at gate $gate_name — reviewed by <other family> alone`. Skip the synthesis and cross-review; proceed to 2d. (Record before slot: an interruption between the two leaves an empty slot under a terminal record, never a one-family array under a record that still says `both`.)
- **Neither** → `printf 'both:unavailable\n' > "$REC"`, record a deferral (*"reviewer unavailable — both families"*), proceed to the next gate; no 2d.

**Synthesize** — the same merger `/duet-review` uses, into a fresh temp file, validated, then moved. Exit codes 0/1/2 are verdicts (PASS / REJECT / CONTESTED), all valid here; 2d decides from the buckets:

```bash
rm -f "$V.tmp"; SYNTH_RC=0
~/.claude/skills/koji/bin/koji-duet-synthesize --claude "$A_SLOT" --codex "$B_SLOT" --b-backend codex \
  --base "$SEGMENT_START_SHA" --out "$V.tmp" || SYNTH_RC=$?
case "$SYNTH_RC" in 0|1|2) ;; *) echo "ERROR: synthesizer rc=$SYNTH_RC"; rm -f "$V.tmp"; SYNTH_RC=bad ;; esac
[ "$SYNTH_RC" = bad ] || python3 -c "import json; v=json.load(open('$V.tmp')); assert all(k in v for k in ('verdict','cross_review_required','cross_review_done','high_consensus','high_contested','medium'))" \
  || { echo "ERROR: synthesizer wrote no valid verdict"; rm -f "$V.tmp"; SYNTH_RC=bad; }
[ "$SYNTH_RC" = bad ] && { printf 'both:unavailable\n' > "$REC"; echo "Gate $gate_name: merge failed — recording a deferral (reviewer unavailable — merge)"; }
[ "$SYNTH_RC" = bad ] || mv "$V.tmp" "$V"
CROSS=$(python3 -c "import json; print(str(json.load(open('$V'))['cross_review_required']).lower())" 2>/dev/null || echo skip)
echo "Gate $gate_name attempt $((attempt+1)): merged verdict $(python3 -c "import json; print(json.load(open('$V'))['verdict'])" 2>/dev/null) (cross_review_required=$CROSS)"
```

A `bad` merge is the deferral path above (no 2d). **`CROSS=true`** → **one** cross-review pass, exactly `/duet-review` Step 4a/4b/4c with these files — targets `$RUN_DIR/gate-${gate_id}-attempt-${attempt}-codex-cross-targets.json` (Claude's solo high/medium, for codex to assess) and `…-claude-cross-targets.json` (codex's solo, for Claude), diff = `$SEGMENT_DIFF_FILE`, both cross legs dispatched in parallel and backgrounded: the **codex cross leg** is the 4b Bash block reading its prompt from `…-codex.cross.prompt` into `…-codex.cross.raw/.err/.exit`, classified, checked with `~/.claude/skills/koji/bin/koji-duet-findings-check --cross`, published to `…-codex.cross.json`; the **Claude cross leg** is the 4b Agent call — **Call the `Agent` tool**, a **fresh Agent context, never a fork**, the dispatch rule above (`koji-reviewer-$CLAUDE_EFFORT` / `general-purpose`, `model` per `$CLAUDE_MODEL`), the 4b cross prompt with the read-only clause, fingerprinted with `…-claude.cross.fp` — checked with `--cross`, published to `…-claude.cross.json`. A cross leg that fails (non-`OK`, malformed, never returns once the other is in) → `[]` for that side: safe degrade, its solo findings stay solo. Then re-synthesize through the **same temp → validate → move block** with `--claude-cross "…-claude.cross.json" --codex-cross "…-codex.cross.json" --cross-review-done` added (a stale `$V` can never satisfy the check). Single pass only — do not loop.

Finally publish the slot 2d reads: every HIGH, consensus **and** contested — a contested HIGH still blocks, fail closed at an unattended gate. Entries keep their `agreed_by`, which the consult round routes on:

```bash
python3 -c "
import json
v = json.load(open('$V'))
json.dump(v['high_consensus'] + v['high_contested'], open('$FINDINGS.tmp', 'w'))
print('Gate $gate_name: %d high (%d consensus, %d contested), %d medium' % (len(v['high_consensus'])+len(v['high_contested']), len(v['high_consensus']), len(v['high_contested']), len(v['medium'])))
"
# The downstream slot obeys the same rule as every other: tmp → check → rename, validated or absent.
if ~/.claude/skills/koji/bin/koji-duet-findings-check "$FINDINGS.tmp"; then mv "$FINDINGS.tmp" "$FINDINGS"
else rm -f "$FINDINGS.tmp"; printf 'both:unavailable\n' > "$REC"; echo "Gate $gate_name: merged slot failed validation — recording a deferral (reviewer unavailable — merge)"; fi
```

Then proceed to 2d (a failed merged slot is the deferral path above — no 2d).

### 2d. Decide PASS / FIX / DEFER

```bash
FINDINGS="$RUN_DIR/findings-${gate_id}-attempt-${attempt}.json"
A_SLOT="$RUN_DIR/findings-${gate_id}-attempt-${attempt}-claude.json"
REC="$RUN_DIR/gate-${gate_id}-attempt-${attempt}-backend.txt"
V="$RUN_DIR/gate-${gate_id}-attempt-${attempt}-verdict.json"
RECORD=$(cat "$REC")
STRATEGY=$(~/.claude/skills/koji/bin/koji-duet-setup field "$(head -n1 "$RUN_DIR/duet-setup")" 1) || exit 1
HIGH_COUNT=$(python3 -c "import json; print(sum(1 for f in json.load(open('$FINDINGS')) if f.get('severity')=='high'))")
# Mediums are non-blocking but reported (Step 6). Under `both` they live in the merged verdict, not the HIGH-only slot.
if [ -s "$V" ]; then MED_COUNT=$(python3 -c "import json; print(len(json.load(open('$V'))['medium']))")
else MED_COUNT=$(python3 -c "import json; print(sum(1 for f in json.load(open('$FINDINGS')) if f.get('severity')=='medium'))"); fi

if [ "$HIGH_COUNT" = "0" ]; then
  if [ "$STRATEGY" = "claude-then-codex" ] && [ "$RECORD" = "claude" ]; then
    # Claude found no HIGH. Not a PASS yet: one codex call confirms it on the SAME
    # snapshot. Archive the (already validated) Claude array, empty the slot, THEN
    # arm the record — re-entry (2c) requires all three, and a crash between the
    # steps leaves a plain `claude` record that simply re-reviews, never a false PASS.
    cp "$FINDINGS" "$A_SLOT" && rm "$FINDINGS"
    printf 'claude+codex-confirm\n' > "$REC"
    echo "Gate $gate_name: Claude found no HIGH — codex confirms on the same snapshot before the gate passes"
    # → back to 2c for this SAME attempt: the record selects the codex leg. Do not touch $attempt.
  else
    echo "Gate $gate_name: PASS ($MED_COUNT medium noted)"
    # Snapshot the reviewed tree WITHOUT moving HEAD (the walk never commits): a
    # dangling commit the next gate diffs against, so its review is segment-local
    # instead of cumulative. /wrap commits the real work later.
    git add -A
    PREV_GATE_SHA=$(git commit-tree "$(git write-tree)" -p "$SEGMENT_START_SHA" -m "duet-impl: gate $gate_name snapshot")
    printf '%s\n' "$PREV_GATE_SHA" > "$RUN_DIR/gate-${gate_id}-snapshot.txt"   # durable: the next gate's SEGMENT_START_SHA
    continue   # to next segment
  fi
else
  # High findings present
  if [ "$attempt" -lt "$RETRIES" ]; then
    echo "Gate $gate_name: $HIGH_COUNT high finding(s), attempting fix (retry $((attempt+1))/$RETRIES)"
    # Apply the fixes (see prose below), then:
    attempt=$((attempt+1))
    # Loop back to 2c — a fresh attempt: fresh record, fresh snapshot, Claude first again under claude-then-codex.
  else
    echo "Gate $gate_name: retry budget exhausted, consulting the gate reviewer(s) once"
    # This block ENDS here. Run the consult round ("Consult round" prose below) — a
    # background dispatch, collected on its notification — then run the
    # "After the consult" block. Nothing is recorded or snapshotted yet.
  fi
fi
```

**After the consult** — the consult results are in (`…-consult-<family>.json`, or a failed reply = everything reconfirmed). Rewrite `$FINDINGS` to the HIGHs that were **not** withdrawn by every family in their routing set (tmp → `~/.claude/skills/koji/bin/koji-duet-findings-check` → `mv`), then:

```bash
FINDINGS="$RUN_DIR/findings-${gate_id}-attempt-${attempt}.json"
HIGH_COUNT=$(python3 -c "import json; print(sum(1 for f in json.load(open('$FINDINGS')) if f.get('severity')=='high'))")
if [ "$HIGH_COUNT" = "0" ]; then
  echo "Gate $gate_name: every HIGH withdrawn at consult — PASS"
  # → the PASS branch of 2d (snapshot lines included).
else
  # The loop never blocks:
  # it is a recorded deferral, not a blocking prompt. Record it and proceed —
  # the only posture at gates 1..N-1, unattended-safe by design.
  echo "Gate $gate_name: recording $HIGH_COUNT unresolved high finding(s) as deferred, proceeding"
  # Append the reconfirmed HIGH(s), with their consult guidance, to $RUN_DIR/deferred-findings.md (template below).
  git add -A
  PREV_GATE_SHA=$(git commit-tree "$(git write-tree)" -p "$SEGMENT_START_SHA" -m "duet-impl: gate $gate_name snapshot (deferred)")   # deferred code stays in the cumulative diff
  printf '%s\n' "$PREV_GATE_SHA" > "$RUN_DIR/gate-${gate_id}-snapshot.txt"
  continue   # to next segment
fi
```

The **reviewer-unavailable** terminals from 2c (a Claude leg with no validated array twice under a single-family record; `both:unavailable`; a failed merge) never reach this block: they record a deferral with the stated reason and proceed to the next gate — including the snapshot lines above, so the following gate still diffs segment-locally. Gates 1..N-1 never wait on quota (2c substitutes or degrades), so there is no quota-cap terminal at a gate.

**Docstring/comment findings are corrected on the spot.** A `medium` `style` finding whose description names the "code, not its history" rule (`gate-review-prompt.md`) is applied by the implementer as a comment-only edit — its `suggested_fix.details` — before `continue`, in the PASS branch as well: no attempt consumed, no re-review, since the edit is mechanical and changes no behaviour. It still counts in `MED_COUNT` for the report.

**Deferral artifact (`$RUN_DIR/deferred-findings.md`).** Written with the Write tool — create-with-header on the first deferral of the run, append a `## Gate:` block on each subsequent one (text formatting, so prose-templated, not a helper). Record the finding + *why the retries couldn't resolve it* + the gate:

```markdown
# Deferred findings — /duet-impl run
Plan: <PLAN_FILE>   Run dir: <RUN_DIR>   Start SHA: <START_SHA>
Recorded because the gate could not resolve within RETRIES + consult, or the gate
reviewer was unavailable. The loop never blocks — it defers and proceeds. Code remains
in the cumulative diff — the end-of-run /duet-review re-examines it.

---
## Gate: <gate_name>
- Why deferred: <RETRIES + consult exhausted | reviewer unavailable — malformed reply ×2 | reviewer unavailable — both families | reviewer unavailable — merge>
- Findings (<HIGH_COUNT>):
  - `<file>:<line>` [<category>] <description>
    fix: <suggested_fix.details>
    consult: <RECONFIRM guidance, when a consult round ran>
```

When retrying (the `if` branch above), apply each high finding before looping back to 2c: read `$FINDINGS` and, for every finding with `severity == high`, invoke the Edit tool with that finding's `suggested_fix.details` to apply the fix — same mechanism as `/duet-review` Step 5d. This is a tool action, not a shell call; there is no batch helper. Any docstring or comment the fix touches follows the same "code, not its history" rule as 2b — re-read it before moving on.

**Consult round.** Per the autonomy principle, this is the "agents try together" step *before* recording a deferral. Route it by the record: `codex` / `both:codex-only` / `claude+codex-confirm` → the codex leg; `claude` / `both:claude-only` / `codex-quota-substituted` / `codex-error-substituted` → the Claude leg (those two records mean Claude produced the findings — codex never withdraws Claude's HIGH); `both` → **both legs in parallel**, and a HIGH is withdrawn only when **every** family in its `agreed_by` says so. Each leg is the same mechanism as its 2c leg: the codex `exec -` block reading `…-consult.prompt`; for Claude, **Call the `Agent` tool** — a **fresh Agent context, never a fork**, dispatch rule, read-only clause — with the standing HIGHs inlined. The consult prompt:

> *"You flagged these high findings on gate '$gate_name'. The implementer made $RETRIES fix attempts that you still flagged. For each finding, either RECONFIRM it with specific code-level guidance the implementer can apply, or WITHDRAW it if your earlier finding may have been mistaken given the work as-is. Output STRICT JSON only — an array of {"fingerprint": "<file>:<line>:<category>", "verdict": "RECONFIRM" | "WITHDRAW", "guidance": "one line"}. No markdown fences."*

Results go to `$RUN_DIR/gate-${gate_id}-attempt-${attempt}-consult-<codex|claude>.json`, each checked with `~/.claude/skills/koji/bin/koji-duet-findings-check --consult`; a reply that fails the check (or never comes) reconfirms everything — fail closed. A fingerprint absent from a family's reply is reconfirmed by that family. The reconfirmed HIGHs go to the deferral with their `guidance` line.

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

- `subagent_type`: `general-purpose` — deliberately not a `koji-reviewer-*` agent: this is an auditor, not a reviewer, and it inherits the session's effort
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
- **Setup → pass the tuple.** Phrase it as *"duet setup: `<tuple>`"*, read from `$RUN_DIR/duet-setup`. The loaded `/duet-review` validates it and uses it verbatim — no setup prompt, no save; its Reviewer B is codex under every strategy but `claude`, because the final gate is the cross-model one. Quota-intent words (e.g. "retry every 10 minutes") travel too, since that skill's back-off governs the final gate.

- **Depth → follows the tuple.** This is the *comprehensive* final review: with Claude effort `max` the loaded skill runs the 5-angle fan-out itself (`REVIEW_MODE=fanout`); under `inherit` at `/effort max` likewise. In exactly those two cases also say "full review / all angles", so a phrase-level override can never drop it to a single pass. With Claude effort `high` or `xhigh` say nothing about depth — the phrase "full review" is a fan-out override in that skill and would silently 5× the cost the user just declined.

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
Setup:     <koji-duet-setup summary of $RUN_DIR/duet-setup> [(claude effort fell back to inherit — agents not installed)]
Reviewers: <gate-1>=codex <gate-2>=claude+codex-confirm <gate-3>=both:codex-only → final: <codex | claude-B>
Gates:     <gate-1> ✓ → <gate-2> ⚠deferred → <gate-3> ✓ (retries: 0, 2, 0)
Mediums:   <gate-1>: 2 (style ×1, deadcode ×1) — <findings or verdict file>; <gate-3>: 1 (codebase-fit ×1) — <file>
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

The `Setup:` line is `koji-duet-setup summary` of `$RUN_DIR/duet-setup`, with the bracketed note when `$RUN_DIR/claude-effort-fallback` exists. The `Reviewers:` line reads each gate's **last attempt's** `gate-*-backend.txt` — `codex`, `claude`, `both`, `both:claude-only`, `both:codex-only`, `both:unavailable`, `claude+codex-confirm`, `claude+codex-unavailable`, `codex-quota-substituted`, `codex-error-substituted` — and the final review's Reviewer B from its own header. When any gate's record has no codex component (`claude`, `codex-*-substituted`, `both:claude-only`, `claude+codex-unavailable`) or the strategy is `claude`, append the same-model caveat from `/duet-review`'s Step 6 in one line. Repeat any `⚠ working tree changed …` line that fired during a Claude-leg gate.

The `Mediums:` line prints only when some gate's last attempt carried medium findings — one entry per gate: the count, a per-category tally, and the file(s) to read: `findings-<gate>-attempt-<n>.json`; the `…-verdict.json` `medium` bucket under `both`; and under a `claude+codex-*` record **both** the slot (codex's array) and the archived `…-claude.json` (Claude's mediums live only there — the confirm replaced the slot). Non-blocking, informational; the run dir is kept, so the entries are inspectable.

## Failure modes

| Symptom | Cause | Mitigation |
|---|---|---|
| Codex review at gate hangs | `--enable web_search_cached` re-introduced, or stdin not closed | Skill explicitly drops both — verify bash not modified |
| Codex exits 124 at a gate | Gate diff too large, or the codex effort exceeded the 30-min wall | Pick `high` in the duet setup, a smaller retry budget (`RETRIES=1`, faster fail), smaller gate scopes |
| Codex quota/rate-limit (or ERROR/TIMEOUT/EMPTY) at gates 1..N-1 | 5-hour session limit depleted mid-run, or codex failed to start / reply | `koji-codex-classify` returns a non-`OK` state (never `[]` for quota). `codex` strategy → the gate is re-reviewed immediately by a fresh-context Claude subagent (Step 2c Claude leg), recorded `codex-*-substituted`; `both` → the gate proceeds on Claude alone (`both:claude-only`, no cross-review); `claude-then-codex` confirm → the gate passes on the Claude verdict (`claude+codex-unavailable`). The next gate tries codex again. Never a silent PASS, never a wait |
| Gate record `both:unavailable`, or deferral reason `reviewer unavailable — merge` | Both families failed terminally at one attempt, or the synthesizer produced no valid verdict | Recorded deferral; the walk proceeds; the final `/duet-review` re-examines the code. Inspect the attempt's `.raw` / `.claude.txt` files in the run dir |
| Codex quota at the final gate (embedded `/duet-review`) | Same, at the cross-model review | That skill's own back-off: `QUOTA_BACKOFF`s × `QUOTA_MAX_WAITS`, auto-resuming; cap → its degraded banner. The final gate is never substituted |
| Claude-leg gate reviewer returns prose / no array | Prompt drift on the substitute or `claude`-mode reviewer | Retry once with the format reminder; second failure → deferral "reviewer unavailable — malformed reply ×2", `$FINDINGS` removed, walk proceeds. Never `[]`, never `koji-codex-classify` on Claude output |
| `⚠ working tree changed while a read-only reviewer was in flight` | Claude-leg reviewer edited despite the read-only clause, or the user kept working | Unattributed by design. `git status`; if the reviewer edited, discard its edits and re-run the gate |
| `koji-duet-backend` exits 3: `duet setup file missing/invalid … run state lost` | `$RUN_DIR/duet-setup` is gone or unreadable — the run dir was cleaned, or a block ran with the wrong `RUN_DIR` substituted | Re-substitute `RUN_DIR`. If the file is truly gone, resume with `FROM_GATE` on a fresh run — the helper never defaults to codex on a lost file, since that would silently weaken a `both` / `claude-then-codex` walk |
| `ERROR: confirm re-entry without the attempt's diff/prompt/Claude archive` | A `claude+codex-confirm` record survived but the attempt's snapshot files did not | Run state lost for that attempt: delete the record file and re-run the gate (`FROM_GATE`) so the attempt starts clean with Claude |
| `⚠ koji-reviewer-<x> not installed` | The reviewer agent definitions were never linked (koji upgraded without re-running `setup`, or the session predates the install) | Claude legs ran on `general-purpose` at inherited effort; the Step 6 `Setup:` line says so. Run `setup`, restart the session |
| Gate unresolved after retries + consult | Genuine hard finding | Recorded to `$RUN_DIR/deferred-findings.md`, walk proceeds (never blocks); deferred code stays in the cumulative diff so the end-of-run `/duet-review` re-examines it |
| Implementer-applied fix doesn't compile | Suggested_fix.details was wrong for the actual context | Counts as a retry attempt; the next gate review will flag the new issue. Up to budget |
| Stuck on a "scope" finding (the reviewer says work overshoots phase) | Plan was ambiguous, or implementer interpreted broadly | Consult round usually resolves; if not, record a deferral and proceed |
| Promise audit (Step 3a) times out, returns prose, or emits unparseable JSON | Auditor agent drift, or transient model issue | Write `[]`, log `WARN: promise audit returned no parseable JSON …`, proceed to Step 3b. Audit is a guardrail, not a gate — `/duet-review` still runs |
| Promise audit reports gaps but `/duet-review` PASSes | Reviewers didn't share the audit's specific-contract checklist (the failure mode this audit exists for) | Gaps appear in Step 6 summary and Step 4 reconciliation blockquote. User decides to fix or accept as known deviation |
| `$DOCS_PATH` not set | `/koji-init` never run | Same as `/wrap` |

## Related

- Autonomy principle: [../references/agent-autonomy.md](../references/agent-autonomy.md)
- Duet setup and reviewer backend (the tuple; strategies; substitution rule; slot rule; read-only clause): [../references/reviewer-backend.md](../references/reviewer-backend.md)
- Gate review prompt: [references/gate-review-prompt.md](references/gate-review-prompt.md)
- Promise audit prompt: [references/promise-audit-prompt.md](references/promise-audit-prompt.md)
- Upstream producer: `/duet-plan` saves the plan files `/duet-impl` consumes
- End-of-run pass: `/duet-review` provides the 2-reviewer adversarial verdict
