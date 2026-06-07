---
description: "Autonomous, lean, cross-model hardening of a LOCKED plan: drives gstack's /plan-eng-review inline, and for each genuinely contentious finding runs a Claude+codex vote on one proposed resolution that auto-locks on consensus. One end-of-run erratum ratifies — and nothing is written until it does. Invocation requires the 'triangulate-review' intent (distinct from bare /triangulate). Requires gstack AND codex."
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Agent
  - AskUserQuestion
  - WebSearch
  - WebFetch
  - TaskCreate
  - TaskUpdate
  - Skill(plan-eng-review)
---

# /plan-triangulate-review

> Follows the [agent-autonomy principle](../references/agent-autonomy.md): agents resolve technical questions together; users see prompts only for cost safety, deadlocks, and the final ratification.

Run an **autonomous, lean, cross-model hardening pass** over a locked plan. This skill drives gstack's `/plan-eng-review` **inline** (you become its reviewer), and for each finding it **triages** — most findings it resolves solo by reading the cited source; only the genuinely contentious ones get a **Claude + codex vote on a single proposed resolution** that **`consensus (both AGREE) auto-locks`**. At the end, ONE ratification prompt (the *erratum*) surfaces the decisions — and **`nothing is written to the plan until you ratify`**.

It is the first-class home for the hand-driven loop koji ran ad-hoc — made reproducible and drift-guarded. It is **not** a fan-out: the reference run hardened a locked ADR in **4 model calls across 2 findings**. If a run is spawning tens of agents, the triage discipline has broken.

## When to invoke

Use when the user types `/plan-triangulate-review`, says "plan-triangulate-review `<plan>`", "triangulate-review this plan", "harden this plan with cross-model review", or similar — the **"triangulate-review" intent is required** (the same way the duet family requires the `duet` keyword). Do NOT route a bare "triangulate" here (that's `/triangulate`, the multi-side debate) or a generic "review this plan" (that's gstack `/plan-eng-review`). This is a deliberate, **cost-guarded** entry: it is model-invocable for a clearly-intended request like the one above, but **never auto-trigger it on a plan just because one exists** — it spends real model calls.

Operates on a **locked** plan (e.g. one `/duet-plan` produced, or any structured plan/ADR). The plan's substeps are **not** relitigated — this pass *hardens* the decisions already made, additively.

## Dependencies & startup

**gstack AND codex are REQUIRED.**
- **gstack** supplies the review lens — the eng-manager cognitive patterns and the Architecture / Code-Quality / Test / Performance sections of `/plan-eng-review`. **eng-only at v1**: `/plan-devex-review` is dimension-*scoring*, not finding-by-finding; `/plan-ceo-review` and `/plan-design-review` are holistic — skip all three.
- **codex** is the second voice in every debate. Auto-locking on a single model's vote is meaningless, so without codex there is no honest cross-model consensus — it is a hard dependency, not a degrade.

## Preamble

```bash
# Hard dependencies, probed FIRST — before keepawake, so a missing-dep exit never
# leaks a caffeinate. Both are clean exits (a missing dependency is not an error).
if [ ! -f "$HOME/.claude/skills/gstack/plan-eng-review/SKILL.md" ]; then
  echo "plan-triangulate-review needs gstack's /plan-eng-review (the review lens it hardens). Install gstack, then re-run."
  exit 0
fi
if ! command -v codex >/dev/null 2>&1; then
  echo "plan-triangulate-review needs codex on PATH (the second voice in every debate)."
  echo "Without it there is no cross-model consensus to auto-lock on. Install codex, then re-run."
  exit 0
fi

source <(~/.claude/skills/koji/bin/koji-detect)
echo "=== koji plan-triangulate-review ==="
echo "Project: $PROJECT_NAME"
```

## Arguments / plan resolution

The plan path comes from the user's invocation (intent, not flags):

| User said | How to resolve |
|---|---|
| `plan-triangulate-review plans/adr-015.md` | direct path |
| `plan-triangulate-review the port-shape plan` | glob `$PLANS_DIR/*port-shape*.md`; 1 match → use; multiple → AskUserQuestion to pick |
| `plan-triangulate-review` (no plan) | AskUserQuestion to pick from `$PLANS_DIR/*.md` |

**Codex effort: default xhigh, opt down by saying so** (same rule as `/triangulate` and `/duet-review`). Drop to `high` only on an explicit lighter-effort signal. Claude inherits the parent session's effort.

---

## Step 1 — Cost guard (the FIRST of only ~3 prompts)

Before any model spend or keep-awake, show a one-time estimate and get one opt-in (a legitimate **cost-safety** prompt under [agent-autonomy.md](../references/agent-autonomy.md)). The finding count is unknowable until the review runs, so the estimate is a **ceiling** — say so honestly:

> Hardening `<plan>` with `/plan-eng-review` + per-finding Claude↔codex debate.
> Up to ~`F` findings × 2 voices × ≤3 rounds at `<xhigh|high>` — but **most findings resolve by reading source with zero model calls; only genuinely contentious ones spend.** codex runs serial (~up to 30 min worst case each). Reference run: 4 calls / 2 findings.

`AskUserQuestion` — options: **Proceed (recommended)** / **Lighter (codex `high`)** / **Include Outside-Voice red-team** (+1 fresh agent; default OFF for leanness; see Step 4) / **Cancel** (`exit 0`; nothing spawned).

## Step 2 — Start the review (keep-awake, run dir, then drive plan-eng-review inline)

```bash
~/.claude/skills/koji/bin/koji-keepawake start || true   # once; torn down once in Step 8
RUN_DIR=$(mktemp -d -t ptr-XXXXXX)   # per-finding debate artifacts
FINDING_N=0                           # incremented per DEBATED finding (file naming)
```

Keep these running counters in your head for the report + log: **`TRIAGED`** (every finding surfaced, any bucket), **`DEBATED`** (went to a vote), **`STILL_SPLIT`** (hit the round cap), **`UNRESOLVED`** (still-splits you left open at escalation — usually 0, since escalation resolves them).

**Create the progress task list** — `TaskCreate` one task per review section (Architecture / Code-Quality / Tests / Performance) + a final "Erratum + ratification" task; keep it current as you walk.

**Then invoke `/plan-eng-review` via the Skill tool and run its review SECTIONS inline.** The contract:

- **You ARE the agent running `/plan-eng-review`.** You execute its review sections in this context and see every finding it surfaces.
- **koji owns the write-back, not gstack's plan-mode end-flow.** This skill does **not** enter plan mode. So you use plan-eng-review's *review sections* (the lens + findings + Outside Voice) but you do **not** run its host-plan-file detection, its `## GSTACK REVIEW REPORT` write, or its ExitPlanMode gate — koji's erratum (Step 7) is the in-plan artifact, and koji logs the pass explicitly (Step 7b). Driving inline does NOT auto-log for you.
- **Adopt spawned-session behavior for ceremony.** Auto-pick the recommended option for plan-eng-review's routing/telemetry/preamble prompts; skip its non-review ceremony. Do **NOT** set `OPENCLAW_SESSION` (it would also gag the ratification AUQ, which this skill owns).
- **Step-0 Scope Challenge is an input to triage, not a prompt.** The plan is locked; record its observations as context and proceed (gstack's own rule: once scope is agreed, commit fully).

## Step 3 — Per finding: triage, then debate only the contentious ones

**Stream per finding** — handle each finding as it surfaces; never gather all findings up front (later findings are adaptive; the Outside Voice spawns new ones). For each, **TRIAGE** into exactly one of:

- **refute-solo** — you can show it's wrong by reading the cited source (Read tool). Record the refutation; no debate, no model call.
- **record-solo** — clearly correct and uncontentious. Record acceptance; no debate, no model call.
- **debate** — genuinely contentious: you cannot settle it by reading source, or it would *flip a locked decision*. Only these go to Step 3a.

Count every finding you triage in **`TRIAGED`** (any bucket) — it feeds the review log's `issues_found`. **`Debate is the exception, not the default`.** Most findings resolve refute-solo or record-solo. If you are debating most findings, the triage discipline this skill exists to enforce has broken.

**Do not fire plan-eng-review's per-section AskUserQuestion for a finding.** The triage + (maybe) debate + the single end-of-run ratification (Step 6) is the one user gate — see "Autonomy reconciliation" below; this override is deliberate.

### Step 3a — The debate (Claude + codex vote on ONE proposed resolution)

A debate is a vote on a **single proposed resolution**, not an open-ended "what do you think." This is load-bearing: without a shared proposition, two voices can both say "AGREE" while meaning *different* fixes. So FIRST commit to the **proposed resolution** you'd lock (from your triage read), then ask both voices to vote on exactly that.

```bash
FINDING_N=$((FINDING_N + 1)); ROUND=1   # ROUND floors the per-round filenames so a re-debate never reads round 1's stale files
```

Build each voice's prompt with the **big-picture lens** baked in **from finding #1** (derive the downstream phases by reading the plan's roadmap):

```
FINDING: <plan-eng-review's finding>
OPTIONS: <the finding's options, if any>
PROPOSED RESOLUTION: <the ONE specific call being voted on>

BIG-PICTURE LENS: this plan ships in phases. Downstream phases (from the plan):
- <Phase name> — <what it changes>
- <…enumerate the named downstream phases…>
Does any downstream phase ABSORB this decision (make it moot) or FLIP it (force a
different shape)? Address this explicitly in your reasoning.

Close with EXACTLY one line — a vote on the PROPOSED RESOLUTION above:
  VERDICT: AGREE      (you support the proposed resolution as written), or
  VERDICT: DISAGREE   (you do not — name the alternative you would take)
Then one paragraph: your reasoning + the crux.
```

Dispatch both voices in parallel, backgrounded, each to its own file:

- **Claude voice** — `Agent` tool, `run_in_background: true`, `general-purpose`. When it returns, **you (the main agent) write its full output to `$RUN_DIR/finding-$FINDING_N-r$ROUND-claude.md`** via the Write tool — the subagent does not write the file.
- **codex voice** — embedded bash, `run_in_background: true` (the canonical koji dispatch; `< /dev/null` + timeout wrapper are the confirmed silent-hang guards):

```bash
EFFORT="${EFFORT:-xhigh}"; TIMEOUT="${TIMEOUT:-1800}"   # set EFFORT=high BEFORE this block if the user picked "Lighter" at Step 1
TO=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || echo "")
CF="$RUN_DIR/finding-$FINDING_N-r$ROUND-codex.md"
# $CODEX_PROMPT = the finding + options + proposed resolution + lens + the
# VERDICT-closing instruction above.
if [ -n "$TO" ]; then
  "$TO" "$TIMEOUT" codex exec "$CODEX_PROMPT" -C "$PROJECT_ROOT" -s read-only \
    -c "model_reasoning_effort=\"$EFFORT\"" < /dev/null > "$CF.raw" 2> "$CF.err"
else
  codex exec "$CODEX_PROMPT" -C "$PROJECT_ROOT" -s read-only \
    -c "model_reasoning_effort=\"$EFFORT\"" < /dev/null > "$CF.raw" 2> "$CF.err"
fi
CE=$?; echo "$CE" > "$CF.exit"
# Only a CLEAN exit is a real vote. Timeout (124) or any nonzero → DISAGREE, so a
# half-finished "AGREE" can NEVER auto-lock. (Copy raw only on success.)
if [ "$CE" = "0" ]; then
  cp "$CF.raw" "$CF"
else
  printf 'VERDICT: DISAGREE\n(codex exit %s — failed/timeout, not a real vote)\n' "$CE" > "$CF"
fi
```

### Step 3b — Consensus, rounds, the cap

When BOTH voice files exist, check consensus (the `VERDICT:` parse is render-unsafe, so it lives in `bin/`):

```bash
~/.claude/skills/koji/bin/koji-triangulate-review-consensus \
  "$RUN_DIR/finding-$FINDING_N-r$ROUND-claude.md" "$RUN_DIR/finding-$FINDING_N-r$ROUND-codex.md"
# exit 0 → both AGREE on the proposed resolution → auto-lock it
# exit 1 → split → another round (if ROUND < cap) or escalate (if at the cap)
```

- **`consensus (both AGREE) auto-locks`** the proposed resolution — no per-finding prompt. Record the locked decision + any concession (who conceded, on what evidence). `DEBATED=$((DEBATED+1))`.
- **`hard round cap = 3`** — no user-extendable hatch (unlike lone `/triangulate`). Most findings settle in round 1.
- **Round 2/3** — bump `ROUND=$((ROUND + 1))` FIRST, so this round writes fresh `-r$ROUND-` files and the consensus check reads *this* round's pair, never round 1's. Then refine the proposed resolution if the dissent warrants, and re-dispatch both voices with each one's prior output verbatim + the other's + the close: **"Either (a) prove your position with a concrete scenario, (b) concede now and say so plainly, or (c) propose a new test that genuinely decides it. Be honest — if the other voice is right, say so."** A generic "argue again" does not produce clean concessions; this close does.
- **Still split at the cap** → `STILL_SPLIT=$((STILL_SPLIT+1))`; escalate (a permitted AUQ): present both positions + the crux; the user picks. **If no AskUserQuestion is callable here** (headless host), do not auto-pick — this is BLOCKED exactly like Step 6's no-AUQ path: write nothing, log nothing, go to Step 8. The user's pick *resolves* the finding (not unresolved); only bump `UNRESOLVED` if they explicitly leave it open.

Then return to plan-eng-review's next finding.

## Step 4 — Outside-Voice red-team (optional; only if opted in at Step 1)

`/plan-eng-review` ends with an optional **Outside Voice** (a fresh AI challenges the finished plan → new findings). When you reach it:

- **Do NOT fire the Outside Voice's per-tension AskUserQuestion.** Its tensions resolve through the same triage→debate→erratum path as any finding.
- **Red-team each Outside-Voice finding first** — dispatch one fresh `Agent` with the findings verbatim + permission to read the codebase, stance *"Try to REFUTE each finding. Don't accept a claim unless the evidence forces you to."* Per finding it returns `Verdict: SOLID | PARTIAL | REFUTED | UNCLEAR` + evidence (`file:line`) + a refutation attempt. Then:
  - **SOLID** → fold into the erratum; if architectural, debate it like any finding (Step 3a).
  - **PARTIAL** → route to the `/duet-impl` absorption list in the erratum.
  - **REFUTED** → drop, no action. (On the reference run this refuted 2 of 12 Outside-Voice findings — including one that would have reverted a multi-round-locked decision.)
  - **UNCLEAR** → add to the still-split set, surfaced at the erratum.

## Step 5 — Assemble the erratum (draft only — nothing is written yet)

Build the erratum **in memory** from the locked decisions, concessions, absorption items, and still-split items. Do NOT touch the plan file or the review log yet — **`nothing is written to the plan until you ratify`** (Step 6). Draft shape:

```markdown
## Cross-model hardening erratum — <YYYY-MM-DD>

_Additive. The locked plan above is unchanged. /plan-eng-review run inline with
per-finding Claude+codex debate (via /plan-triangulate-review)._

### Decisions locked (one line each)
- <finding> → <resolution> (<both AGREE | refuted-solo | recorded-solo | user-resolved>)

### Cross-model concessions
- Claude conceded on <X>: <one line, with the deciding evidence>.
- codex conceded on <Y>: <one line>.

### /duet-impl absorption list
- [ ] <PARTIAL/SOLID item routed forward> — <where it lands>

### Still split (surfaced to you)
- <finding> — <Claude pos> vs <codex pos> after 3 rounds; you picked <…>.
```

## Step 6 — Ratify (the single end-of-run AUQ)

Fire ONE `AskUserQuestion` — the erratum ratification. Show the decisions-locked list + concessions + still-split. Options: **Ratify** (Step 7 writes it) / **Amend a decision** (adjust, then re-confirm) / **Discard** (write nothing, go to Step 8). This is the single user gate; the whole autonomous run passes through it.

**No-AUQ → BLOCKED.** If no `AskUserQuestion` variant is callable (headless/spawned host), do **NOT** write the erratum, do **NOT** log the review, and do **NOT** auto-decide. Report `BLOCKED — AskUserQuestion unavailable` and stop (after Step 8 cleanup). This mirrors gstack's own contract: a plan-eng-review without a usable AUQ is BLOCKED, never silently auto-ratified. Writing the decisions anyway — or logging a "clean" review for `/ship` — would be the exact dump-and-skip shortcut the whole design forbids.

## Step 7 — On ratify: write-back

Only after the user **ratifies** (Step 6). On Discard, skip to Step 8.

**7a. Append the erratum to the plan** (additive; locked substeps untouched — amendment-governance never edits a locked substep). The erratum is koji's in-plan artifact: koji does not enter plan mode, so there is no `## GSTACK REVIEW REPORT` and no ExitPlanMode gate to satisfy.

**7b. Log the eng-review pass once** so `/ship`'s readiness dashboard sees it. koji drives this **explicitly** — gstack's own report writer auto-detects a host plan-mode file that is NOT present for a directly-invoked koji skill, so do not rely on it; emit the log yourself, exactly once, **with `via`**:

```bash
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "")
# issues_found = every finding surfaced (TRIAGED), not just the debated few.
# unresolved/status reflect genuinely-open decisions AFTER ratification: a
# still-split the user resolved at escalation is NOT unresolved — UNRESOLVED
# defaults to 0 and counts only ones the user explicitly left open.
STATUS="clean"; [ "${UNRESOLVED:-0}" -gt 0 ] && STATUS="issues_open"
~/.claude/skills/gstack/bin/gstack-review-log "{\"skill\":\"plan-eng-review\",\"timestamp\":\"$TS\",\"status\":\"$STATUS\",\"unresolved\":${UNRESOLVED:-0},\"critical_gaps\":0,\"issues_found\":${TRIAGED:-0},\"mode\":\"FULL_REVIEW\",\"via\":\"plan-triangulate-review\",\"commit\":\"$COMMIT\"}"
```

This single call (one emission, with `via`) makes `/ship` show `CLEAR (PLAN via /plan-triangulate-review)`.

**7c. Accumulate voice positions into the research topic-file.** `decisions-merge` requires its target to already exist, so **create the topic file first when it's new**, then merge:

```bash
SLUG=$(~/.claude/skills/koji/bin/koji-triangulate-persist slug "<content-area>")
TOPIC="$RESEARCH_DIR/$SLUG.md"
if [ ! -f "$TOPIC" ]; then
  mkdir -p "$RESEARCH_DIR"
  { ~/.claude/skills/koji/bin/koji-triangulate-persist emit-frontmatter research unvalidated
    printf '\n# %s\n\n## Decisions\n' "<topic title>"; } > "$TOPIC"
fi
# build the dated section into $NEW_SECTION_FILE (a temp file), then:
~/.claude/skills/koji/bin/koji-triangulate-persist decisions-merge "$TOPIC" "$NEW_SECTION_FILE"
```

## Step 8 — Cleanup + report

```bash
~/.claude/skills/koji/bin/koji-keepawake stop || true   # once, on EVERY exit path (ratify, discard, BLOCKED, escalation)
[ "${KEEP:-0}" = "1" ] || rm -rf "$RUN_DIR"
```

```
plan-triangulate-review: <ratified | discarded | BLOCKED | concerns>
Plan:      <plan-path>
Findings:  <T triaged> — <R refuted-solo> / <K recorded-solo> / <DEBATED debated>
Debate:    <DEBATED findings, M model calls, C concessions, STILL_SPLIT still-split>
Review:    logged once (via plan-triangulate-review) — /ship dashboard updated   [omit if discarded/BLOCKED]
Erratum:   appended to <plan>                                                    [omit if discarded/BLOCKED]
```

---

## Leanness contract (the anti-fan-out rule — load-bearing)

- **Triage before debating** — only contentious findings get voices; refute/record the rest solo.
- **`Debate is the exception, not the default`.**
- **`Stream per finding`** — one at a time; no upfront fan-out over all findings.
- **`consensus (both AGREE) auto-locks`** at round 1 where possible; **`hard round cap = 3`**.
- **2 voices** (Claude + codex) voting on one proposed resolution, not a panel.

Reference run: **4 model calls / 2 findings**. If a run spawns tens of agents, it has regressed to a fan-out. (`bin/koji-selfcheck` canaries that these markers still live in this file; it fails loud at install if an edit guts them.)

## Autonomy reconciliation with gstack's per-finding rule (do NOT revert this)

`/plan-eng-review` requires that every non-trivial finding's path goes THROUGH AskUserQuestion (the May-2026 anti-shortcut guard). This skill deliberately **`substitutes ONE end-of-run ratification`** AUQ (the erratum) for plan-eng-review's per-finding prompts. Safe and principled — and it must be documented so a maintainer does not "fix" it back:

- It is **not** the dump-and-skip shortcut gstack guards against — it is **higher** rigor (cross-model vote per contentious finding) with a final ratification gate, plus the two permitted escalations (cost guard, still-split). Critically, **nothing is written to the plan until you ratify**, and if no AUQ is callable the run is **BLOCKED** (never auto-ratified) — so the path to every write genuinely passes through the user. Reverting this to per-finding AUQ is exactly the regression that produced this skill.

## Failure modes

| Symptom | Cause | Mitigation |
|---|---|---|
| gstack or codex absent | a hard dependency is missing | Preamble probes both and exits 0 (before keep-awake), pointing the user at the missing one. |
| Every finding goes to debate | triage discipline lost | The fan-out regression. Refute/record-solo by reading source; debate only what you can't settle or that flips a locked decision. |
| codex exits 124 at a finding | xhigh ran past 30 min | The dispatch writes `VERDICT: DISAGREE` on any nonzero exit, so it can't auto-lock; another round or escalate. Opt down to `high`. |
| Two voices "both AGREE" but meant different fixes | no shared proposition | Can't happen here — both vote on ONE proposed resolution; AGREE means agreement on that exact call. |
| `/ship` dashboard doesn't show the review | didn't log explicitly | koji must emit `gstack-review-log` itself, once, with `via` (Step 7b) — driving plan-eng-review inline does NOT auto-log for a non-plan-mode run. |
| Research persistence errors on a new topic | `decisions-merge` needs an existing target | Step 7c creates the topic file (frontmatter + `## Decisions`) before merging. |
| AskUserQuestion uncallable | headless/spawned host | BLOCKED — write nothing, log nothing, report `BLOCKED — AskUserQuestion unavailable` (gstack's own rule). |

## Related

- gstack `/plan-eng-review` — the review lens this hardens (its review sections driven inline; never modified).
- `/triangulate` — the pure single-question debate engine; this skill reuses its **method** + `bin/` persistence (`koji-triangulate-persist`), not the skill itself.
- `/duet-impl` — consumes the erratum's absorption list.
- Autonomy principle: [../references/agent-autonomy.md](../references/agent-autonomy.md).
- Drift canary: `bin/koji-selfcheck`. Consensus helper: `bin/koji-triangulate-review-consensus`.
