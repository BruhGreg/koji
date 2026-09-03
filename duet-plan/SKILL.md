---
description: "Multi-round Claude↔codex planning dialogue. Saves the agreed plan to $DOCS_PATH/plans/. Invocation requires the 'duet' keyword."
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

# /duet-plan

> Follows the [agent-autonomy principle](../references/agent-autonomy.md): agents resolve technical questions together; users see prompts only for policy choices and unresolved deadlocks.

## When to invoke

Use ONLY when the user explicitly types `/duet-plan`, says "duet plan", "duet-plan", "let's duet plan X", or similar — the `duet` keyword is required. Do NOT invoke on casual "let's plan" or "help me plan" phrases (too generic). Agents debate autonomously; user is escalated only when consensus stalls at the round limit.

Multi-round Claude↔codex planning dialogue. Each round, Claude drafts/updates a plan and the reviewer critiques — codex by default, or a fresh-context Claude subagent per `.koji.yaml` `duet.reviewer` (see **Reviewer backend** below). The skill detects consensus via `VERDICT:` markers; when both agents emit `AGREE` in the same round, the plan is saved to `$DOCS_PATH/plans/<slug>.md`. Process artifacts (round drafts and critiques) stay in `/tmp` and are cleaned up at end of run.

## Preamble

```bash
source <(~/.claude/skills/koji/bin/koji-detect)
echo "=== koji duet-plan ==="
echo "Project: $PROJECT_NAME"
echo "Docs: $DOCS_PATH"
echo "Reviewer: ${DUET_REVIEWER:-codex} (claude model: ${DUET_CLAUDE_MODEL:-inherit}, codex effort: ${DUET_CODEX_EFFORT:-xhigh})"
```

## Arguments / topic extraction

The topic is whatever the user provided. Examples of how to extract it:

| User said | Topic |
|---|---|
| "duet plan how we add OAuth" | "how we add OAuth" |
| "let's duet plan refactoring the auth module" | "refactoring the auth module" |
| "duet-plan: migrate from postgres 14 to 15" | "migrate from postgres 14 to 15" |
| "duet plan" (no topic) | ask user once via AskUserQuestion |

**Intent, not flags** — koji skills read natural-language intent; there is no argv to parse. When the user's phrasing signals one of these, set the matching internal variable before Step 1; otherwise the default holds:

- **Round limit** → `ROUNDS`. The dialogue runs up to 5 rounds by default. If the user caps it ("at most 3 rounds", "two rounds max", "one quick round"), set `ROUNDS` to that number.
- **Slug override** → `SLUG`. The plan's filename slug is auto-derived from the topic. If the user names the file explicitly ("save it as oauth-migration", "call the plan X"), set `SLUG` to that name.
- **Keep process artifacts** → `KEEP`. The `/tmp` round drafts and critiques are cleaned up at end of run. If the user asks to keep them ("keep the scratch files", "don't clean up", "leave the round drafts for debugging"), set `KEEP=1`.

**Codex effort: default xhigh, opt down by saying so.** Codex runs at `xhigh` (~30-min timeout, ~2.5× tokens). The agent should drop to `high` (~15-min timeout, ~1× tokens) ONLY when the user's invocation phrase signals lighter effort — e.g., "quick check", "lighter pass", "use high effort", "save tokens", "fast pass". Don't downgrade for "the diff looks small" or similar heuristics; only on explicit user signal. Claude inherits the parent session's effort level — set `/effort max` once before running if you want max-tier Claude.

## Reviewer backend

The adversarial voice is **codex by default**. `.koji.yaml` `duet.reviewer` selects it — config, not intent, never from the phrase; `koji-detect` validates the value, warns on stderr and falls back to codex on a typo. Full contract (mapping table, read-only clause, quota rule, slot rule): [`../references/reviewer-backend.md`](../references/reviewer-backend.md).

- **`codex`** (default) — codex critiques every round; consensus = drafter `AGREE` + codex `AGREE`.
- **`claude`** — a **fresh-context Claude subagent** (never a fork) critiques every round; consensus = two Claude contexts agreeing, reported as `CONSENSUS REACHED at round N (claude-only)`. A quota escape hatch: same model family, weaker disagreement signal — the lock header records it.
- **`claude-rounds+codex-final`** — Claude critiques every round, and **every round that would lock is gated by one codex call in the same round** (2c). Codex `AGREE` locks; `PARTIAL`/`DISAGREE` sends the dialogue into another Claude round against codex's critique. Clean case: exactly one codex call per plan. Stateless — the only record is `round-N-backend.txt`, written before every dispatch.

**Quota rule.** A codex `QUOTA` / `ERROR` / `TIMEOUT` on an *ordinary* round is re-run immediately by the Claude backend (visible `⚠`, recorded as `codex-*-substituted`), and the next round tries codex again. The round that would lock is *final*: there a codex quota **waits** (`QUOTA_BACKOFF` × `QUOTA_MAX_WAITS`, the same knobs `/duet-impl` uses) and never substitutes — so a lock always carries a codex verdict unless `reviewer: claude` was chosen.

**Prose, not JSON.** Unlike `/duet-review` and `/duet-impl`, this skill's codex output is a prose critique ending in a `VERDICT:` line. Its codex leg classifies with `koji-codex-classify … --prose`, which accepts exit 0 + a VERDICT line as `OK` *before* any quota-marker scan. Never copy the JSON-mode 5-state branch from those skills into this one — a healthy critique that merely *mentions* quota would be labeled `QUOTA` (this happened live) and every good round would fail.

## Step 1 — Setup

```bash
RUN_DIR=$(mktemp -d -t duet-plan-XXXXXX)
TOPIC="<topic from invocation>"
echo "$TOPIC" > "$RUN_DIR/topic.txt"

# Reviewer backend (see "Reviewer backend" above) — from .koji.yaml via koji-detect.
REVIEWER="${DUET_REVIEWER:-codex}"             # codex | claude | claude-rounds+codex-final
CLAUDE_MODEL="${DUET_CLAUDE_MODEL:-inherit}"   # Claude-backend reviewer model; inherit → omit the Agent `model` param
# Effort: see "Codex effort" above for the opt-down rule. The NL signal (EFFORT set
# before this block) wins; otherwise the .koji.yaml duet.codex_effort default.
EFFORT="${EFFORT:-${DUET_CODEX_EFFORT:-xhigh}}"
TIMEOUT="${TIMEOUT:-1800}"
ROUND_LIMIT="${ROUNDS:-5}"
QUOTA_BACKOFF="${QUOTA_BACKOFF:-900}"      # codex quota back-off at the LOCK GATE only (s), default 15 min
QUOTA_MAX_WAITS="${QUOTA_MAX_WAITS:-20}"   # cap on lock-gate back-offs (~5h)
# Loop state — re-substituted by the agent each block (each Bash block is a fresh shell).
LOCK_WAITS="${LOCK_WAITS:-0}"              # lock-gate quota back-offs used so far (the gate itself is read from round-N-backend.txt, not a variable)
B_RETRIED="${B_RETRIED:-0}"                # Claude-leg missing-VERDICT retry used this round (0/1)
TO=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || echo "")
PROMPT_TEMPLATES="$KOJI_SKILLS/duet-plan/references/prompt-templates.md"
PROJECT_CONTEXT="(repo: $(basename "$PROJECT_ROOT"); branch: $(git branch --show-current 2>/dev/null || echo unknown))"

echo "Topic: $TOPIC"
echo "Run dir: $RUN_DIR"
echo "Round limit: $ROUND_LIMIT, effort: $EFFORT, reviewer: $REVIEWER (claude model: $CLAUDE_MODEL)"

# Keep the machine awake for this unattended run — the background dialogue can
# span many minutes and rounds. Refcounted + self-cleaning; never touches a
# caffeinate the user started. Torn down in Step 5. No /wrap dependency.
~/.claude/skills/koji/bin/koji-keepawake start || true
```

## Step 2 — Dialogue loop (both agents run in background)

Each round has two model calls (Claude drafts, then the reviewer critiques). Both run as **background tasks** so the user can keep working on other things while the dialogue progresses. After each launch, briefly tell the user what's running and **return control**. Resume processing only when the harness re-invokes you with a completion notification.

Sequence within a round is fixed (the reviewer needs Claude's draft to critique it), so the two background calls happen back-to-back, not in parallel. But across the round's launches, the user is free.

Implement as a counter starting at 1. Repeat until consensus or round limit.

### Round 1 (initial)

#### 2a. Claude drafts initial plan (Agent tool, background)

Call the `Agent` tool with `run_in_background: true`:

- `subagent_type`: `general-purpose`
- `description`: `Duet plan round 1: Claude draft`
- `prompt`: the "CLAUDE — initial round" template from [references/prompt-templates.md](references/prompt-templates.md), with `{topic}` / `{project_root}` / `{project_context}` filled in
- `run_in_background`: `true`

Tell the user: *"Round 1: Claude drafting the plan in the background. You can continue with other work."* Then return control.

When the Agent completion notification arrives, the result is in the notification's `<result>` block. Write that to `$RUN_DIR/round-1-claude.md` via the Write tool. Confirm the last line is `VERDICT: AGREE` / `PARTIAL` / `DISAGREE`. If the response is missing the VERDICT marker, the agent should re-invoke the same Agent call once with a reminder to include the marker.

#### 2b. Reviewer critiques (background)

Resolve and **record this round's backend before dispatch**. The file is the only durable record across Bash blocks (each block is a fresh shell), Step 3 builds the lock header from these files, and 2c reads it to decide whether a lock needs the codex gate:

```bash
ROUND=1
CLAUDE_FILE="$RUN_DIR/round-${ROUND}-claude.md"
CODEX_FILE="$RUN_DIR/round-${ROUND}-codex.md"   # the critique SLOT — both backends write here; koji-duet-verdict reads it

# The lock-gate state lives ON DISK in the round's backend record, never in a
# shell variable: each Bash block is a fresh shell, and a dropped in-memory flag
# here would re-resolve the backend to claude, overwrite the record 2c just
# wrote, and loop the gate forever. `*+codex-final` ⇒ 2c armed the gate for
# this round; anything else ⇒ an ordinary round.
case "$(cat "$RUN_DIR/round-${ROUND}-backend.txt" 2>/dev/null)" in
  *+codex-final)
    ROUND_BACKEND=codex; LOCK_GATE=1 ;;   # the lock gate is always codex; do NOT rewrite the record
  *)
    ROUND_BACKEND=$(~/.claude/skills/koji/bin/koji-duet-backend plan-round)   # codex | claude — stateless helper
    printf '%s\n' "$ROUND_BACKEND" > "$RUN_DIR/round-${ROUND}-backend.txt"
    LOCK_GATE=0 ;;
esac
echo "Round $ROUND reviewer: $ROUND_BACKEND (lock gate: $LOCK_GATE)"
```

Then **run the leg matching `ROUND_BACKEND`**. Either leg fills the same "## REVIEWER — every round" template from `$PROMPT_TEMPLATES` — `{topic}`, `{project_root}`, `{claude_plan}` = contents of `$CLAUDE_FILE`, `{prior_critique_or_empty}` = the previous round's critique slot when one exists (empty on round 1 and at the lock gate, where codex reads the plan cold) — and writes its critique to `$CODEX_FILE`. The backend never changes the prompt.

##### 2b — codex leg (`ROUND_BACKEND=codex`)

```bash
# The agent fills the template into $CODEX_PROMPT inline — example shape:
CODEX_PROMPT="You are the adversarial reviewer for a plan drafted by another agent in a separate context...

TOPIC: $TOPIC
REPOSITORY: $PROJECT_ROOT

Claude's current plan:

---
$(cat "$CLAUDE_FILE")
---

(no prior critique on round 1)

End with VERDICT line."

# Prompt goes to a file and codex reads it from stdin (`-`): a plan plus prior
# rounds can exceed the argv ceiling (macOS ARG_MAX ≈ 1 MB shared with env), and
# an E2BIG never starts codex — empty .raw, which downstream reads as "no
# critique". printf is a builtin, so writing the file has no such limit. A
# redirect from a regular file EOFs immediately, preserving the old
# `< /dev/null` guarantee that codex never blocks waiting on stdin. `-` must be
# the ONLY positional: a prompt arg plus piped stdin changes codex's framing.
PROMPT_TXT="$CODEX_FILE.prompt"
printf '%s\n' "$CODEX_PROMPT" > "$PROMPT_TXT"

if [ -n "$TO" ]; then
  "$TO" "$TIMEOUT" codex exec - \
    -C "$PROJECT_ROOT" -s read-only \
    -c "model_reasoning_effort=\"$EFFORT\"" \
    < "$PROMPT_TXT" > "$CODEX_FILE.raw" 2> "$CODEX_FILE.err"
else
  codex exec - \
    -C "$PROJECT_ROOT" -s read-only \
    -c "model_reasoning_effort=\"$EFFORT\"" \
    < "$PROMPT_TXT" > "$CODEX_FILE.raw" 2> "$CODEX_FILE.err"
fi
echo $? > "$CODEX_FILE.exit"
```

Run this Bash block with **`run_in_background: true`**. Tell the user: *"Round $ROUND: codex critiquing in the background."* Then return control.

When the notification arrives, **classify in prose mode** — `--prose` is mandatory here (see "Reviewer backend": this output is a prose critique, and without `--prose` a healthy critique that mentions quota is labeled `QUOTA`):

```bash
CODEX_STATE=$(~/.claude/skills/koji/bin/koji-codex-classify \
  "$CODEX_FILE.raw" "$CODEX_FILE.err" "$CODEX_FILE.exit" --prose)
case "$(cat "$RUN_DIR/round-${ROUND}-backend.txt" 2>/dev/null)" in *+codex-final) LOCK_GATE=1 ;; *) LOCK_GATE=0 ;; esac
echo "Round $ROUND codex state: $CODEX_STATE (lock gate: $LOCK_GATE)"
case "$CODEX_STATE" in
  OK)    cp "$CODEX_FILE.raw" "$CODEX_FILE" ;;
  EMPTY) if [ "$LOCK_GATE" = "1" ]; then
           # No VERDICT at the gate is not a verdict: record DISAGREE so the round cannot lock.
           echo "VERDICT: DISAGREE: codex returned no VERDICT at the lock gate" > "$CODEX_FILE"
         else
           echo "WARN: codex critique has no VERDICT line — it cannot lock this round"
           cp "$CODEX_FILE.raw" "$CODEX_FILE"   # verdict reads UNKNOWN → no consensus; the critique text stays for the drafter
         fi ;;
  *)     echo "codex $CODEX_STATE on round $ROUND — see the substitution rule" ;;
esac
```

On `QUOTA` / `ERROR` / `TIMEOUT`:

- **Ordinary round (`LOCK_GATE=0`)** — this review is not final, so **do not wait**: print `⚠ codex $CODEX_STATE — round $ROUND reviewed by fresh-context Claude`, overwrite the backend record (`printf 'codex-quota-substituted\n'` for `QUOTA`, `printf 'codex-error-substituted\n'` otherwise) into `$RUN_DIR/round-${ROUND}-backend.txt`, and run the **Claude leg below** for this same round with the same filled prompt. The next round tries codex again — substitution is per-review, not a mode switch. If the substituted round then reaches AGREE+AGREE, 2c's lock gate fires (the record is not `codex`), so `reviewer: codex` plus a quota hit can never lock on a Claude-only verdict.
- **Lock gate (`LOCK_GATE=1`)** — this review IS final; **never substitute**. `QUOTA` → if `LOCK_WAITS < QUOTA_MAX_WAITS`: tell the user *"lock gate: codex quota — backing off ${QUOTA_BACKOFF}s, retry $((LOCK_WAITS+1))/${QUOTA_MAX_WAITS}"*, dispatch a backgrounded `sleep "$QUOTA_BACKOFF"; <the codex exec - … block above>` reading the same `$PROMPT_TXT` (an identical retry; keepawake is already held), increment `LOCK_WAITS`, return control, re-classify on notification. Cap reached → go to **Deadlock at round limit** with the reason *"codex unavailable at the lock gate"* (its option 5 waits and retries). `ERROR` / `TIMEOUT` → `echo "VERDICT: DISAGREE: codex $CODEX_STATE at the lock gate" > "$CODEX_FILE"`: no lock this round; `ROUND++` and the next round re-resolves its backend.

If the Claude substitute itself fails twice (below), use the same fail-closed terminal: `echo "VERDICT: DISAGREE: reviewer returned no VERDICT after retry" > "$CODEX_FILE"` and surface the deadlock prompt — the reviewer is unavailable, so the user decides.

##### 2b — Claude leg (`ROUND_BACKEND=claude`, or a codex substitution)

Record the tree state first — the Claude backend has no `-s read-only` sandbox, only an instruction, so the run detects (not prevents) a reviewer that edits:

```bash
: "${CODEX_FILE:?CODEX_FILE unset — re-substitute it in this block}"   # an empty prefix would write ".fp" into the repo root
~/.claude/skills/koji/bin/koji-tree-fingerprint > "$CODEX_FILE.fp"   # compared on collection
```

**Call the `Agent` tool** — a literal tool call; do not narrate "spawning a reviewer" and write the critique yourself. The reviewer runs in a **fresh Agent context, never a fork** — a fork inherits the drafter's reasoning, which is exactly the blind spot an adversarial round exists to expose.

- `subagent_type`: `general-purpose`
- `description`: `Duet plan round <ROUND>: reviewer critique (Claude)`
- `model`: **omit this parameter** when `$CLAUDE_MODEL` is `inherit`; otherwise pass its value (`fable` / `opus` / `sonnet`)
- `prompt`: the same filled "## REVIEWER — every round" template the codex leg composes, followed by the **read-only clause** from `../references/reviewer-backend.md`
- `run_in_background`: `true`

Tell the user: *"Round $ROUND: Claude reviewer critiquing in the background."* Then return control. When the notification arrives, Write the `<result>` text to `$CODEX_FILE` — the slot — via the Write tool. Confirm the last line is a `VERDICT:` marker. If it is missing and `B_RETRIED=0`, set `B_RETRIED=1` and re-invoke the same Agent call once with *"Your last response was missing the VERDICT line — re-output the same critique with the marker appended."*; a second miss → the DISAGREE terminal above. **Do not run `koji-codex-classify` on it.** Then compare the tree fingerprint:

```bash
FP_NOW=$(~/.claude/skills/koji/bin/koji-tree-fingerprint)
[ "$FP_NOW" = "$(cat "$CODEX_FILE.fp" 2>/dev/null)" ] \
  || echo "⚠ working tree changed while a read-only reviewer was in flight (reviewer or concurrent work) — review snapshot may be stale"
```

#### 2c. Check consensus — and the lock gate

```bash
# Verdict parsing lives in a helper: an inline awk `$1` field ref would be
# silently stripped by the skill renderer, so consensus would never be detected.
KOJI_VERDICT=~/.claude/skills/koji/bin/koji-duet-verdict
CLAUDE_V=$("$KOJI_VERDICT" "$CLAUDE_FILE")
CODEX_V=$("$KOJI_VERDICT" "$CODEX_FILE")
ROUND_BACKEND=$(cat "$RUN_DIR/round-${ROUND}-backend.txt" 2>/dev/null || echo codex)   # missing file ⇒ codex (pre-v0.8.0 layout)
echo "Round $ROUND verdicts: drafter=$CLAUDE_V reviewer=$CODEX_V (backend: $ROUND_BACKEND)"

CONSENSUS=0
LOCK_GATE=0
if [ "$CLAUDE_V" = "AGREE" ] && [ "$CODEX_V" = "AGREE" ]; then
  case "$ROUND_BACKEND" in
    codex|*+codex-final)
      # A codex verdict is in the slot — either the round ran on codex, or the
      # lock gate below already ran this round and codex agreed.
      echo "CONSENSUS REACHED at round $ROUND"
      CONSENSUS=1 ;;
    *)
      # Ask the helper, not a Step 1 variable: this block is a fresh shell, and an
      # empty $REVIEWER would send a pure-claude run into the codex gate.
      if [ "$(~/.claude/skills/koji/bin/koji-duet-backend review-b)" = "claude" ]; then
        echo "CONSENSUS REACHED at round $ROUND (claude-only)"
        CONSENSUS=1
      else
        # Would lock on a Claude review (hybrid mode, or a quota-substituted round
        # under codex mode) → one codex call gates the lock, in this same round.
        echo "Round $ROUND would lock on a Claude review — running the codex lock gate before locking."
        cp "$CODEX_FILE" "$RUN_DIR/round-${ROUND}-claude-critique.md"   # archive (cp, not mv — crash-safe)
        rm "$CODEX_FILE"   # empty the slot: only the lock gate's codex verdict may fill it now
        printf '%s+codex-final\n' "$ROUND_BACKEND" > "$RUN_DIR/round-${ROUND}-backend.txt"
        LOCK_GATE=1
      fi ;;
  esac
fi
```

**When `LOCK_GATE=1`:** run **2b's codex leg** again for this same round number — the drafter's plan is unchanged; `{prior_critique_or_empty}` is empty so codex reads the plan cold, which is the point of a cross-model gate — then re-run this 2c block. The slot is written only on `OK`; a `QUOTA` at the gate waits (2b lock-gate rule), `ERROR`/`TIMEOUT` records `DISAGREE`. Codex `AGREE` → `CONSENSUS=1` (the record now reads `<backend>+codex-final`). `PARTIAL`/`DISAGREE` → no consensus; `ROUND++`, and 2d hands the drafter codex's critique. Clean case — the drafter converges under Claude review and codex agrees at the gate — is **exactly one codex call**; every further lock attempt costs one more. `rm "$CODEX_FILE"` before the gate is what makes this safe: a crash mid-gate leaves an empty slot and the archived Claude critique, never a Claude `AGREE` masquerading as codex's.

### Round N (N > 1, when not yet consensus and ROUND ≤ ROUND_LIMIT)

#### 2d. Drafter responds (Agent tool, background)

Call the `Agent` tool with `run_in_background: true`, using the "CLAUDE — subsequent rounds" template, filling in:
- `{topic}`
- `{claude_previous}` = contents of `$RUN_DIR/round-$((ROUND-1))-claude.md`
- `{codex_critique}` = contents of `$RUN_DIR/round-$((ROUND-1))-codex.md` (the previous round's critique slot — whichever backend filled it; after a rejected lock gate that is codex's critique)

Tell the user: *"Round $ROUND: Claude responding to the reviewer's critique in the background."* Then return control.

Write response to `$RUN_DIR/round-$ROUND-claude.md`.

#### 2e. Reviewer re-critiques

Same as 2b — the backend is resolved and recorded again for this round (`LOCK_GATE=0`, `B_RETRIED=0`) — but pass `{prior_critique_or_empty}` = contents of `$RUN_DIR/round-$((ROUND-1))-codex.md` so the reviewer remembers what was said last round and can check whether the drafter addressed it.

#### 2f. Consensus check (same as 2c)

### Deadlock at round limit

When ROUND exceeds ROUND_LIMIT without consensus — or the reviewer is unavailable (lock-gate quota cap reached, or a Claude-leg reviewer returned no VERDICT twice) — surface to the user via `AskUserQuestion`. This is the autonomy-doc "deadlocked planning consensus" case.

```
Question: "Planning consensus not reached after $ROUND_LIMIT rounds. How to proceed?"
      (or: "The reviewer is unavailable — codex quota at the lock gate after $QUOTA_MAX_WAITS back-offs. How to proceed?")
Body: include the last 2 rounds' verdicts and a 1-paragraph summary of the disagreement
Options:
  1. "Lock Claude's last plan as-is (override the reviewer)"
  2. "Lock the reviewer's recommended version (extract from last critique)"
  3. "Add 3 more rounds and try again"
  4. "Abort and discard"
  5. "Wait and retry the codex lock gate"   ← offered only when the deadlock came from the lock gate:
     resets LOCK_WAITS=0 and re-dispatches the lock gate's codex leg (same $PROMPT_TXT); back-off resumes
```

## Step 3 — Save the plan

When CONSENSUS=1 (or user picked option 1 or 2 above):

```bash
PLANS_DIR="$DOCS_PATH/plans"
mkdir -p "$PLANS_DIR"

# Auto-derive slug from topic unless the user named one (SLUG set)
SLUG="${SLUG:-$(printf '%s' "$TOPIC" | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-60)}"
[ -n "$SLUG" ] || SLUG="untitled-plan"

# Auto-suffix on conflict (<slug>.md → <slug>-2.md → -3, etc.)
OUT="$PLANS_DIR/$SLUG.md"
N=2
while [ -e "$OUT" ]; do
  OUT="$PLANS_DIR/${SLUG}-${N}.md"
  N=$((N + 1))
done

# Strip trailing VERDICT line(s) from the agreed plan body so the saved file is clean.
PLAN_BODY=$(python3 -c "
import re, sys
content = open('$RUN_DIR/round-${ROUND}-claude.md').read()
lines = content.rstrip('\n').splitlines()
while lines and (not lines[-1].strip() or re.match(r'^\s*VERDICT\s*:', lines[-1], re.I)):
    lines.pop()
print('\n'.join(lines))
")

# Configured backend for the header. Fresh shell: fall back to koji-detect rather
# than trusting a Step 1 variable to have survived.
[ -n "${REVIEWER:-}" ] || { eval "$(~/.claude/skills/koji/bin/koji-detect 2>/dev/null)"; REVIEWER="${DUET_REVIEWER:-codex}"; }

# Per-round reviewer record for the lock header, rebuilt from the backend files
# 2b/2c wrote (parameter expansion only — render-safe; no cross-block state).
# Rounds are single digits at the default limit, so glob order is round order.
ROUND_LOG=""
for f in "$RUN_DIR"/round-*-backend.txt; do
  [ -f "$f" ] || continue
  n="${f##*/round-}"; n="${n%-backend.txt}"
  ROUND_LOG="${ROUND_LOG}r${n}=$(cat "$f") "
done
ROUND_LOG="${ROUND_LOG% }"

# Save with minimal frontmatter inline (status field feeds koji-plans-research).
# duet-* fields record who reviewed: e.g. `r1=claude r2=claude r3=claude+codex-final`
# (hybrid, clean case), `r2=codex-quota-substituted` (a substituted round).
DATE=$(date -u +%Y-%m-%d)
cat > "$OUT" <<EOF
---
status: pending
origin-session: $DATE
target: implementation
duet-reviewer: $REVIEWER
duet-rounds: $ROUND
duet-round-reviewers: $ROUND_LOG
---

$PLAN_BODY
EOF

echo "Plan saved: $OUT"
```

If any `⚠ working tree changed …` fired during a Claude-backend round, add `duet-note: working tree changed during a Claude-backend review (unattributed)` to the frontmatter block above before saving. Report the saved path to the user.

## Step 4 — Research capture (optional, judgment-gated)

The multi-round dialogue often produces substantial investigation as a
byproduct of converging on the plan — web fetches, code reads, alternatives
weighed, dead-ends considered. Sometimes that byproduct is the higher-value
artifact (future you wants the model and reasoning, not just the plan).

Apply the criteria in [`../references/research-capture-eval.md`](../references/research-capture-eval.md)
to the dialogue that just happened. If the reference's signals fire (judgment,
not checkbox), surface the exit-prompt from that reference. Otherwise stay
silent — no prompt, no mention.

If the user accepts, run the topic-overlap scan from
[`../references/research-capture-eval.md`](../references/research-capture-eval.md)
(Topic-overlap check + Naming convention sections) against `$RESEARCH_DIR`.
Then either:

- **Append** to the strongest overlap target — prepend a new
  `### YYYY-MM-DD` subsection under that file's `## Decisions`.
- **Write** a new content-area-named topic-file with the accumulating
  structure (`## Decisions` / `## Open questions` / `## Cross-refs`).

Existing topic-files take precedence — do not spawn a parallel file when a
strong overlap exists. The slug for new files is the agent-derived
content-area name (1-3 words, names the *thing being studied* — NOT the
planning session or skill that produced the finding). Auto-suffix on slug
collision only when overlap-scan returned no candidates yet the chosen
content-area name collides with an unrelated existing file.

## Step 5 — Cleanup

```bash
if [ "${KEEP:-0}" = "1" ]; then
  echo "Process artifacts kept at: $RUN_DIR"
else
  rm -rf "$RUN_DIR"
  echo "Process artifacts cleaned up."
fi
~/.claude/skills/koji/bin/koji-keepawake stop || true   # release keep-awake started in Step 1
```

## Step 6 — Report

Print a brief summary:

```
duet-plan: locked
Topic:    <topic>
Path:     <PLANS_DIR>/<slug>.md
Rounds:   <N> (limit was <LIMIT>)
Reviewer: <codex | claude | claude-rounds+codex-final> — <ROUND_LOG, e.g. r1=claude r2=claude+codex-final>
Final verdicts: drafter=<V>, reviewer=<V>
```

When `REVIEWER=claude`, or any round record reads `codex-*-substituted`, add one line: *"Note: same-model round(s) — a fresh Claude context reviewed, not codex; weaker cross-model signal."* Repeat any `⚠ working tree changed …` line that fired.

If the user wants to immediately continue with `/duet-impl`, mention the locked path so they can pass it in.

## Failure modes

| Symptom | Likely cause | Mitigation |
|---|---|---|
| Codex hangs (no output, no timeout) | `--enable web_search_cached` re-introduced, or stdin not redirected from the prompt file | Skill explicitly drops the flag and reads the prompt from `$PROMPT_TXT` — verify bash blocks not modified. Kill PID; an ordinary round then substitutes Claude, the lock gate records DISAGREE. |
| Codex exits 124 (timeout) | Round prompt got too long (cumulative context) | Skill writes prior rounds as files, not stuffs them all into one prompt. If still hitting limit: ask for a lower round limit (`ROUNDS`) or `high` instead of `xhigh`. Ordinary round → Claude substitute; lock gate → DISAGREE, next round. |
| Codex quota / rate-limit on an ordinary round | 5-hour window depleted | Not final → substituted immediately by a fresh-context Claude reviewer (2b), recorded `r<N>=codex-quota-substituted` in the lock header; next round tries codex again. |
| Codex quota at the lock gate | Same, at the round that would lock | Final → backs off `QUOTA_BACKOFF` × `QUOTA_MAX_WAITS` on the same prompt file (keepawake held); cap → deadlock prompt option 5 "Wait and retry the codex lock gate". Never substituted — a lock carries a codex verdict. |
| Healthy codex critique classified `QUOTA` | The codex leg was classified without `--prose` (JSON-mode branch copied from `/duet-review`) | This skill's output is prose; `--prose` accepts a VERDICT line as OK before the quota scan. Restore the flag. |
| Claude drafter (Agent) returns prose without VERDICT line | Prompt drift — agent forgot the marker | Re-invoke the Agent with an explicit reminder: "Your last response was missing the VERDICT line — re-output the same plan with the marker appended." Limit to 1 retry. |
| Claude-backend reviewer returns no VERDICT twice | Prompt drift on the reviewer side | Round records `VERDICT: DISAGREE: reviewer returned no VERDICT after retry` (cannot lock) and the deadlock prompt is surfaced — the reviewer is unavailable, the user decides. Never `koji-codex-classify` on Claude output. |
| Lock header reads `r3=claude+codex-final` | Hybrid mode, or a quota-substituted round under `codex`, locked via the codex gate | Expected — this is the cross-model gate doing its job. |
| `⚠ working tree changed while a read-only reviewer was in flight` | A Claude-backend reviewer edited despite the read-only clause, or the user kept working | Unattributed by design. `git status`; discard reviewer edits if any. The plan itself is text — the critique stands. |
| `duet.reviewer` typo in `.koji.yaml` | Enum validation in `koji-detect` | Warns on stderr, falls back to `codex` — check the preamble's `Reviewer:` line. |
| Plan saves to wrong slug | Auto-slug from topic | Name the file explicitly (sets `SLUG`) to override. Existing files get auto-suffixed (`-2`, `-3`). |
| `$DOCS_PATH` not set | `/koji-init` never run | Same failure mode as `/wrap` — surface and direct user to `/koji-init`. |

## Related

- Autonomy principle: [../references/agent-autonomy.md](../references/agent-autonomy.md)
- Reviewer backend (codex | claude | hybrid; lock gate; quota rule; read-only clause): [../references/reviewer-backend.md](../references/reviewer-backend.md)
- Round prompt templates: [references/prompt-templates.md](references/prompt-templates.md)
- Downstream consumer: `/duet-impl` reads the saved plan and walks the gates
